# fleet.access: hosts managed with SSH keys only.
#
# Accounts for the fleet's users on this host (from `fleet.users`, see
# mkNixos), each with the keys of its ssh.pub and no password; sshd without
# password or root login; sudo for admins against the forwarded SSH agent
# (pam_rssh, which checks the same authorized keys sshd does); and every
# fleet host's SSH host key in known_hosts.  A host can deviate from all of it:
# the sshd policy and shells sit just above nixpkgs' own mkDefaults (its
# installation profiles allow root), the rest is mkDefault.
#
# Standalone (without the `fleet` argument) `fleet.access.users` is set by hand.
{
  config,
  lib,
  options,
  pkgs,
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
  # above NixOS's own mkDefault, below a host's plain setting
  aboveNixosDefault = lib.mkOverride 900;
  adminKeys = lib.concatMap (u: u.keys) (lib.filter (u: u.admin) (builtins.attrValues cfg.users));
  inherit (import ../lib/address.nix { inherit lib; }) namesOf addressOf;
  shells = lib.unique (lib.filter (s: s != null) (lib.mapAttrsToList (_: u: u.shell) cfg.users));
  thisHost =
    if config.fleet.meta.host != null then config.fleet.meta.host else config.networking.hostName;

  # One block per host, and one for its initrd when it has an initrd key. The
  # known_hosts entries (knownHost below) are named by host name and fqdn (and
  # [name]:port for the initrd); an address that is neither needs an alias.
  sshBlock =
    name: host:
    let
      address = ssh.address host;
      names = lib.unique (namesOf name host);
      aliased = !(builtins.elem address names);
      port = toString cfg.initrd.port;
      block = patterns: opts: "Host ${patterns}\n" + lib.concatMapStrings (o: "  ${o}\n") opts;
    in
    block (lib.concatStringsSep " " names) (
      [ "HostName ${address}" ]
      ++ lib.optional (aliased && host ? keys.ssh) "HostKeyAlias ${name}"
      # unless forwardBlock said yes
      ++ [ "ForwardAgent no" ]
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

  # The agent goes to the fleet's hosts for this host's accounts only: never
  # root's, nix-daemon's (remote builds) or a service user's. The first value
  # ssh obtains wins, so this comes before the host blocks.
  forwardBlock = lib.optionalString (ssh.forwardAgent && cfg.users != { }) ''
    Match originalhost ${
      lib.concatStringsSep "," (lib.unique (lib.concatLists (lib.mapAttrsToList namesOf fleet.hosts)))
    } localuser ${lib.concatStringsSep "," (builtins.attrNames cfg.users)}
      ForwardAgent yes
  '';

  knownHost =
    name: host:
    lib.optionalAttrs (host ? keys.ssh) {
      ${name} = {
        hostNames = namesOf name host;
        publicKey = host.keys.ssh;
      };
    }
    // lib.optionalAttrs (host ? keys.initrd) {
      "${name}-initrd" = {
        hostNames = map (n: "[${n}]:${toString cfg.initrd.port}") (namesOf name host);
        publicKey = host.keys.initrd;
      };
    };
in
{
  imports = [
    ./agents.nix
    ./nix.nix
    ./network.nix
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
        inherit (u) shell description;
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
            shell = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "zsh";
              description = "Login shell, by its package name (`shell` in user.nix); enabled as a program where NixOS has one.";
            };
            description = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "The account's full name (`description` in user.nix).";
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

    localPasswords = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Accounts keep the passwords set on the machine (users.mutableUsers),
        for the console of a workstation; sshd stays key-only. Off: an
        account is its keys and nothing else.
      '';
    };

    initrd = {
      enable = lib.mkEnableOption ''
        unlocking the root disk over SSH from the initrd: sshd on `initrd.port`
        with the host's initrd key (`host-keys` generator, placed by
        `fleetl host install`), the admins' keys, the uplink from
        fleet.network, and the password agent as root's shell, so a login is
        good for nothing but unlocking. Without fleet.network (no `network`
        block), the initrd uses DHCP'';
      hostKey = lib.mkOption {
        type = lib.types.str;
        # where `fleetl host install` puts it (scripts/fleetl.sh, host_install)
        default = "/etc/secrets/initrd/ssh_host_ed25519_key";
        description = "The initrd's SSH host key.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 2222;
        description = "Port the initrd's sshd listens on, here and (for known_hosts and the `-unlock` ssh blocks) on the other hosts.";
      };
    };

    sshConfig = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          A block per fleet host in /etc/ssh/ssh_config, for every user of this
          host: `ssh <host>` reaches it by name, and `ssh <host>-unlock` its
          initrd (hosts with an initrd key: root, `initrd.port`, no agent).
        '';
      };
      address = lib.mkOption {
        type = lib.types.functionTo lib.types.str;
        default = addressOf;
        defaultText = lib.literalMD "the host's fqdn, else its name (`addressOf` in lib/address.nix)";
        description = "Host data -> the address to connect to (as mkDeploy's `address`).";
      };
      forwardAgent = lib.mkOption {
        type = lib.types.bool;
        default = cfg.sudo;
        defaultText = lib.literalExpression "fleet.access.sudo";
        description = ''
          Forward the SSH agent of this host's accounts (`users`) to fleet
          hosts, which their sudo (pam_rssh) authenticates against. Root,
          nix-daemon and service users never forward theirs. Root on the
          target can use the agent while the connection lasts; a key that
          needs a touch limits that to what the user confirms.
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

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      services.openssh = {
        enable = lib.mkDefault true;
        # above nixpkgs' own mkDefaults (its installation profiles allow root)
        settings = {
          PasswordAuthentication = aboveNixosDefault false;
          KbdInteractiveAuthentication = aboveNixosDefault false;
          PermitRootLogin = aboveNixosDefault "no";
        };
      };

      # No passwords anywhere: an account is its keys (unless localPasswords).
      users.mutableUsers = lib.mkDefault cfg.localPasswords;
      users.users = lib.mapAttrs (_: u: {
        isNormalUser = true;
        shell = lib.mkIf (u.shell != null) (aboveNixosDefault pkgs.${u.shell});
        description = lib.mkIf (u.description != null) (lib.mkDefault u.description);
        uid = lib.mkIf (u.uid != null) (lib.mkDefault u.uid);
        extraGroups = u.groups ++ lib.optional u.admin "wheel";
        openssh.authorizedKeys.keys = u.keys;
      }) cfg.users;

      # pam_rssh reads /etc/ssh/authorized_keys.d/<user>, the keys above.
      security.pam.rssh.enable = lib.mkIf cfg.sudo (lib.mkDefault true);
      security.pam.services.sudo.rssh = lib.mkIf cfg.sudo (lib.mkDefault true);

      # a login shell that NixOS knows as a program must be enabled as one
      programs.zsh.enable = lib.mkIf (builtins.elem "zsh" shells) (lib.mkDefault true);
      programs.fish.enable = lib.mkIf (builtins.elem "fish" shells) (lib.mkDefault true);

      programs.ssh.knownHosts = lib.mkIf (cfg.knownHosts && fleet != null) (
        lib.mkMerge (lib.mapAttrsToList knownHost fleet.hosts)
      );

      programs.ssh.extraConfig = lib.mkIf (ssh.enable && fleet != null) ''
        # fleet.access: the fleet's hosts
        ${forwardBlock}${lib.concatStrings (lib.mapAttrsToList sshBlock fleet.hosts)}
        # whatever follows applies to every host again
        Match all
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
              "; `ssh <host>-unlock` reaches a host's initrd (root, port ${toString cfg.initrd.port}) to unlock its disks while it boots"
          }.
        '';
      };
    })

    # Unlocking the root disk from the initrd: independent of the accounts, the
    # admins' keys are what may log in.
    (lib.mkIf cfg.initrd.enable {
      assertions = [
        {
          assertion = adminKeys != [ ];
          message = "fleet.access.initrd: no admin has an SSH key (users/<name>/ssh.pub, admin = true), so nobody could unlock this host";
        }
      ];

      boot.initrd = {
        systemd.enable = lib.mkDefault true;
        network = {
          enable = true;
          ssh = {
            enable = true;
            inherit (cfg.initrd) port;
            hostKeys = [ cfg.initrd.hostKey ];
            authorizedKeys = adminKeys;
          };
        };
        # The uplink comes from fleet.network; without a `network` block, DHCP
        # on any wired interface (the systemd initrd has no DHCP of its own).
        systemd.network = lib.mkIf (!config.fleet.network.enable) {
          enable = true;
          networks."99-dhcp" = {
            matchConfig.Name = "en* eth*";
            networkConfig.DHCP = "yes";
          };
        };
        systemd.users.root.shell = aboveNixosDefault "/bin/systemd-tty-ask-password-agent";
      };
    })
  ];
}
