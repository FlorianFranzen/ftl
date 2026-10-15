# fleet.access: hosts managed with SSH keys only.
#
# Accounts for the fleet's users on this host (from `fleet.users`, see
# mkNixos), each with the keys of its ssh.pub and no password; sshd without
# password or root login; sudo for admins against the forwarded SSH agent
# (pam_rssh, which checks the same authorized keys sshd does); and every
# fleet host's SSH host key in known_hosts.  Everything is mkDefault, so a host
# can deviate.
#
# Standalone (without the `fleet` argument) `fleet.access.users` is set by hand.
{
  config,
  lib,
  ...
}@args:

let
  cfg = config.fleet.access;

  fleet = args.fleet or null;
  hostUsers =
    if fleet == null then
      { }
    else
      lib.filterAttrs (_: u: builtins.elem fleet.self.name u.hosts) fleet.users;

  knownHost =
    name: host:
    lib.optionalAttrs (host ? keys.ssh) {
      ${name} = {
        hostNames = [ name ] ++ lib.optional (host ? fqdn) host.fqdn;
        publicKey = host.keys.ssh;
      };
    }
    // lib.optionalAttrs (host ? keys.initrd) {
      "${name}-initrd" = {
        hostNames = map (n: "[${n}]:${toString cfg.initrdPort}") (
          [ name ] ++ lib.optional (host ? fqdn) host.fqdn
        );
        publicKey = host.keys.initrd;
      };
    };
in
{
  options.fleet.access = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.users != { };
      defaultText = lib.literalExpression "fleet.access.users != { }";
      description = "Manage this host's accounts, sshd and sudo for SSH keys only.";
    };

    users = lib.mkOption {
      default = lib.mapAttrs (_: u: {
        inherit (u) admin uid groups;
        keys = u.keys.ssh;
      }) hostUsers;
      defaultText = lib.literalExpression "the fleet users with an account on this host";
      description = "Accounts on this host.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            admin = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "In wheel, with sudo through the SSH agent.";
            };
            keys = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "SSH public keys that may log in (and sudo).";
            };
            uid = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
            };
            groups = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Extra groups.";
            };
          };
        }
      );
    };

    sudo = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        sudo authenticates against the forwarded SSH agent (pam_rssh) with the
        user's authorized keys, instead of a password.
      '';
    };

    knownHosts = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Every fleet host's SSH host key (and initrd key) in known_hosts.";
    };

    initrdPort = lib.mkOption {
      type = lib.types.port;
      default = 2222;
      description = "Port the hosts' initrd sshd listens on, for their initrd keys in known_hosts.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.openssh = {
      enable = lib.mkDefault true;
      settings = {
        PasswordAuthentication = lib.mkDefault false;
        KbdInteractiveAuthentication = lib.mkDefault false;
        PermitRootLogin = lib.mkDefault "no";
      };
    };

    # No passwords anywhere: an account is its keys.
    users.mutableUsers = lib.mkDefault false;
    users.users = lib.mapAttrs (_: u: {
      isNormalUser = true;
      uid = lib.mkIf (u.uid != null) (lib.mkDefault u.uid);
      extraGroups = u.groups ++ lib.optional u.admin "wheel";
      openssh.authorizedKeys.keys = u.keys;
    }) cfg.users;

    # pam_rssh reads /etc/ssh/authorized_keys.d/<user>, the keys above.
    security.pam.rssh.enable = lib.mkIf cfg.sudo (lib.mkDefault true);
    security.pam.services.sudo.rssh = lib.mkIf cfg.sudo (lib.mkDefault true);

    programs.ssh.knownHosts = lib.mkIf (cfg.knownHosts && fleet != null) (
      lib.mkMerge (lib.mapAttrsToList knownHost fleet.hosts)
    );
  };
}
