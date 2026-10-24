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

  ssh = cfg.sshConfig;
  thisHost =
    if config.fleet.meta.host != null then config.fleet.meta.host else config.networking.hostName;
  yesNo = b: if b then "yes" else "no";

  # One block per host, and one for its initrd when it has an initrd key. The
  # known_hosts entries (knownHost below) are named by host name and fqdn (and
  # [name]:port for the initrd); an address that is neither needs an alias.
  sshBlock =
    name: host:
    let
      address = ssh.address host;
      names = lib.unique ([ name ] ++ lib.optional (host ? fqdn) host.fqdn);
      aliased = !(builtins.elem address names);
      port = toString cfg.initrdPort;
      block = patterns: opts: "Host ${patterns}\n" + lib.concatMapStrings (o: "  ${o}\n") opts;
    in
    block (lib.concatStringsSep " " names) (
      [ "HostName ${address}" ]
      ++ lib.optional (aliased && host ? keys.ssh) "HostKeyAlias ${name}"
      ++ [ "ForwardAgent ${yesNo ssh.forwardAgent}" ]
      ++ lib.optionals (ssh.controlPersist != null) [
        "ControlMaster auto"
        "ControlPath ${ssh.controlPath}"
        "ControlPersist ${ssh.controlPersist}"
      ]
    )
    + lib.optionalString (host ? keys.initrd) (
      block "${name}-unlock" (
        [
          "HostName ${address}"
          "Port ${port}"
          "User root"
        ]
        ++ lib.optional aliased "HostKeyAlias [${name}]:${port}"
        ++ [
          "ForwardAgent no"
          "ControlMaster no"
        ]
      )
    );

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
  imports = [
    ./agents.nix
    ./nix.nix
  ];

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

    sshConfig = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          A block per fleet host in /etc/ssh/ssh_config, for every user of this
          host: `ssh <host>` reaches it by name, and `ssh <host>-unlock` its
          initrd (hosts with an initrd key: root, `initrdPort`, no agent).
        '';
      };
      address = lib.mkOption {
        type = lib.types.functionTo lib.types.str;
        default = h: h.fqdn or h.name;
        defaultText = lib.literalExpression "h: h.fqdn or h.name";
        description = "Host data -> the address to connect to (as mkDeploy's `address`).";
      };
      forwardAgent = lib.mkOption {
        type = lib.types.bool;
        default = cfg.sudo;
        defaultText = lib.literalExpression "fleet.access.sudo";
        description = ''
          Forward the SSH agent to fleet hosts, which their sudo (pam_rssh)
          authenticates against. Root on the target can use the agent while
          the connection lasts; a key that needs a touch limits that to what
          the user confirms.
        '';
      };
      controlPersist = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "10m";
        description = ''
          How long a connection to a fleet host stays open for the next ones
          (ControlMaster). They reuse it without authenticating again, so a
          series of commands costs one PIN or touch. null: no multiplexing.
        '';
      };
      controlPath = lib.mkOption {
        type = lib.types.str;
        default = "~/.ssh/cm-%C";
        description = "ControlPath of the multiplexed connections (multiplexing is skipped where it cannot be created).";
      };
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

    programs.ssh.extraConfig = lib.mkIf (ssh.enable && fleet != null) ''
      # fleet.access: the fleet's hosts
      ${lib.concatStrings (lib.mapAttrsToList sshBlock fleet.hosts)}
    '';

    fleet.agents.sections.access = {
      order = 20;
      text = ''
        ## Access

        Accounts here are key-only: no passwords, no root login over SSH.
      ''
      + lib.optionalString cfg.sudo ''

        sudo authenticates against the SSH agent the connecting user forwarded
        (pam_rssh): it fails in a session without a forwarded agent, and a key
        that needs a touch needs one for sudo too. Do not try to work around it
        (no password is set, and none should be).
      ''
      + lib.optionalString (cfg.sudo && config.fleet.nix.enable && !config.fleet.nix.trustWheel) ''

        This host's Nix daemon trusts nobody but root: unsigned paths (a closure
        built elsewhere than on the fleet's builder) arrive through sudo, with the
        forwarded agent:
        `${(import ../lib/agents.nix { inherit lib; }).pushCommand thisHost}`.
      ''
      + lib.optionalString (ssh.enable && fleet != null) ''

        `ssh <host>` reaches every host of the fleet by name, checked against
        its pinned host key${
          lib.optionalString (lib.any (h: h ? keys.initrd) (builtins.attrValues fleet.hosts))
            "; `ssh <host>-unlock` reaches a host's initrd (root, port ${toString cfg.initrdPort}) to unlock its disks while it boots"
        }.
      '';
    };
  };
}
