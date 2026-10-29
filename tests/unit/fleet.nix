# What the fleet's metadata configures besides AGENTS.md: ssh blocks for
# every host, the fleet's binary caches as substituters, the Nix defaults,
# and the repository as a git URL wherever git fetches it.
{
  lib,
  ftl,
  nixpkgs,
  comin,
  fixtureArgs,
  check,
  ...
}:
let
  key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHW437gdXlD8N84nBJqtbi36N1kia4RepapKRaxqlor6 alice";
  # a fleet of its own: a host with a `network` block and initrd unlock, a
  # workstation keeping local passwords, an admin with a shell
  mini = ftl.lib.mkNixos {
    inherit nixpkgs;
    repo = "github:example/fleet";
    hosts = {
      net = {
        network = {
          mac = "52:54:00:12:34:56";
          ipv4 = {
            address = "192.0.2.10";
            prefixLength = 24;
            gateway = "192.0.2.1";
          };
          ipv6 = {
            address = "2001:db8::10";
            prefixLength = 64;
            gateway = "2001:db8::1";
          };
          nameservers = [ "192.0.2.53" ];
        };
        modules = [ { fleet.access.initrd.enable = true; } ];
      };
      # IPv4 only, found by name, its IPv6 address from a delegated prefix
      deleg = {
        fqdn = "deleg.example.org";
        network = {
          interface = "ens3";
          ipv4 = {
            address = "192.0.2.20";
            prefixLength = 32;
            gateway = "192.0.2.1";
          };
          ipv6 = {
            address = "2001:db8:1::1";
            prefixLength = 56;
            delegatedPrefix = "2001:db8:1::/56";
          };
        };
      };
      v4only.network = {
        interface = "eth0";
        ipv4 = {
          address = "192.0.2.30";
          prefixLength = 24;
          gateway = "192.0.2.1";
        };
      };
      # a workstation: local passwords, initrd unlock over DHCP
      ws.modules = [
        {
          fleet.access.localPasswords = true;
          fleet.access.initrd.enable = true;
        }
      ];
    };
    users.alice = {
      admin = true;
      keys.ssh = [ key ];
      shell = "zsh";
      description = "Alice";
    };
  };
  m = host: mini.nixosConfigurations.${host}.config;
  f = ftl.lib.mkFlake (fixtureArgs // { repo = "github:example/fleet"; });
  has = lib.hasInfix;
  cfg = host: f.nixosConfigurations.${host}.config;
  gitUrl = (ftl.lib.repo { inherit lib; }).gitUrl;
in
check "unit-fleet" (
  lib.runTests {
    # ssh <host> for every fleet host, <host>-unlock for those with an initrd key
    testSshBlocks = {
      expr = {
        alpha = has ''
          Host alpha alpha.example.org
            HostName alpha.example.org
            ForwardAgent no
            ControlMaster auto
            ControlPath ~/.ssh/cm-%C
            ControlPersist 10m
          Host alpha-unlock
            HostName alpha.example.org
            Port 2222
            User root
            ForwardAgent no
            ControlMaster no
        '' (cfg "gamma").programs.ssh.extraConfig;
        gamma = has "Host gamma\n  HostName gamma\n" (cfg "alpha").programs.ssh.extraConfig;
        noUnlock = has "gamma-unlock" (cfg "alpha").programs.ssh.extraConfig;
        # the agent for the host's accounts only, by the names given
        forward = has ''
          Match originalhost alpha,alpha.example.org,beta,gamma localuser alice
            ForwardAgent yes
        '' (cfg "gamma").programs.ssh.extraConfig;
        # nothing after the blocks lands in the last of them
        reset = lib.hasSuffix "Match all\n" (cfg "gamma").programs.ssh.extraConfig;
      };
      expected = {
        alpha = true;
        gamma = true;
        noUnlock = false;
        forward = true;
        reset = true;
      };
    };

    # an address that is not a known_hosts name gets an alias
    testSshAlias = {
      expr =
        let
          g = ftl.lib.mkFlake (
            lib.recursiveUpdate fixtureArgs {
              nixos.hosts.gamma.modules = [
                { fleet.access.sshConfig.address = h: if h.name == "alpha" then "192.0.2.1" else h.name; }
              ];
            }
          );
          c = g.nixosConfigurations.gamma.config.programs.ssh.extraConfig;
        in
        {
          host = has "Host alpha alpha.example.org\n  HostName 192.0.2.1\n  HostKeyAlias alpha\n" c;
          unlock = has "  HostKeyAlias [alpha]:2222\n" c;
        };
      expected = {
        host = true;
        unlock = true;
      };
    };

    # a host that substitutes from a fleet cache keeps nixpkgs' gc as it is
    testClientNoGc = {
      expr = {
        client = (cfg "gamma").fleet.client.enable;
        inherit ((cfg "gamma").nix.gc) automatic options;
        # a string or a list, by nixpkgs version
        dates = toString (cfg "gamma").nix.gc.dates;
      };
      expected = {
        client = true;
        automatic = false;
        dates = "03:15";
        options = "";
      };
    };

    testCaches = {
      expr = {
        caches = f.fleet.caches;
        # every other host substitutes from it; the host serving it does not
        gamma = (cfg "gamma").nix.settings.extra-substituters;
        gammaKeys = (cfg "gamma").nix.settings.extra-trusted-public-keys;
        gammaStatus = (cfg "gamma").fleet.client.statusUrl;
        alpha = (cfg "alpha").fleet.client.enable;
      };
      expected = {
        caches = [
          {
            host = "alpha";
            url = "http://alpha.example.org:8080/cache";
            statusUrl = "http://alpha.example.org:8080/status/fixture.json";
            publicKeys = [ "ftl-test-1:6CA2VCkcTQDS8JL6HcoXOOHZWCqjV+3baLKM86c7dcw=" ];
          }
        ];
        gamma = [ "http://alpha.example.org:8080/cache" ];
        gammaKeys = [ "ftl-test-1:6CA2VCkcTQDS8JL6HcoXOOHZWCqjV+3baLKM86c7dcw=" ];
        gammaStatus = "http://alpha.example.org:8080/status/fixture.json";
        alpha = false;
      };
    };

    testNixDefaults = {
      expr = {
        inherit ((cfg "alpha").nix.settings) trusted-users experimental-features;
        channels = (cfg "alpha").nix.channel.enable;
      };
      expected = {
        trusted-users = [ "root" ];
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        channels = false;
      };
    };

    # a @wheel that slipped in elsewhere undoes trustWheel = false: say so
    testTrustWheelWarning = {
      expr =
        let
          g = ftl.lib.mkFlake (
            lib.recursiveUpdate fixtureArgs {
              nixos.hosts.gamma.modules = [ { nix.settings.trusted-users = [ "@wheel" ]; } ];
            }
          );
          warns = c: lib.any (lib.hasInfix "fleet.nix.trustWheel") c.config.warnings;
        in
        {
          slipped = warns g.nixosConfigurations.gamma;
          clean = warns g.nixosConfigurations.alpha;
        };
      expected = {
        slipped = true;
        clean = false;
      };
    };

    # the uplink from the host's `network` block, the same for the initrd
    testNetwork = {
      expr = {
        inherit ((m "net").systemd.network.networks."10-wan") address matchConfig;
        nameservers = (m "net").networking.nameservers;
        networkd = (m "net").networking.useNetworkd;
        initrd = (m "net").boot.initrd.systemd.network.networks."10-wan".address;
        hosts = (m "net").networking.hosts."192.0.2.10";
        # no block, no networking from ftl
        ws = (m "ws").fleet.network.enable;
        deleg = {
          inherit ((m "deleg").systemd.network.networks."10-wan")
            address
            matchConfig
            networkConfig
            dhcpV6Config
            ;
          hosts = (m "deleg").networking.hosts."2001:db8:1::1";
        };
        v4only = {
          inherit ((m "v4only").systemd.network.networks."10-wan") address networkConfig;
          routes = map (r: r.Gateway) (m "v4only").systemd.network.networks."10-wan".routes;
        };
      };
      expected = {
        address = [
          "192.0.2.10/24"
          "2001:db8::10/64"
        ];
        matchConfig.MACAddress = "52:54:00:12:34:56";
        nameservers = [ "192.0.2.53" ];
        networkd = true;
        initrd = [ "192.0.2.10/24" ];
        hosts = [ "net" ];
        ws = false;
        deleg = {
          address = [
            "192.0.2.20/32"
            "2001:db8:1::1/128"
          ];
          matchConfig.Name = "ens3";
          networkConfig = {
            DHCP = "ipv6";
            IPv6AcceptRA = true;
          };
          dhcpV6Config = {
            PrefixDelegationHint = "2001:db8:1::/56";
            WithoutRA = "solicit";
            UseAddress = false;
            UseDNS = false;
          };
          hosts = [
            "deleg.example.org"
            "deleg"
          ];
        };
        v4only = {
          address = [ "192.0.2.30/24" ];
          networkConfig = {
            DHCP = "no";
            IPv6AcceptRA = true;
          };
          routes = [ "192.0.2.1" ];
        };
      };
    };

    # initrd sshd with the initrd key, the admins' keys, the password agent
    testInitrd = {
      expr = {
        inherit ((m "net").boot.initrd.network.ssh) port hostKeys authorizedKeys;
        shell = (m "net").boot.initrd.systemd.users.root.shell;
        # no `network` block: DHCP in the initrd
        ws = (m "ws").boot.initrd.systemd.network.networks."99-dhcp".networkConfig.DHCP;
        noAdmins =
          let
            c =
              (ftl.lib.mkNixos {
                inherit nixpkgs;
                hosts.h.modules = [ { fleet.access.initrd.enable = true; } ];
              }).nixosConfigurations.h.config;
          in
          lib.any (a: !a.assertion && lib.hasInfix "nobody could unlock" a.message) c.assertions;
      };
      expected = {
        port = 2222;
        hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
        authorizedKeys = [ key ];
        shell = "/bin/systemd-tty-ask-password-agent";
        ws = "yes";
        noAdmins = true;
      };
    };

    # shell and description from user.nix; local passwords where asked for
    testAccounts = {
      expr = {
        shell = lib.getName (m "net").users.users.alice.shell;
        inherit ((m "net").users.users.alice) description;
        zsh = (m "net").programs.zsh.enable;
        mutable = {
          net = (m "net").users.mutableUsers;
          ws = (m "ws").users.mutableUsers;
        };
      };
      expected = {
        shell = "zsh";
        description = "Alice";
        zsh = true;
        mutable = {
          net = false;
          ws = true;
        };
      };
    };

    testHostIdAndDomain = {
      expr = {
        hostId = (m "net").networking.hostId;
        domain = (m "deleg").networking.domain;
        noFqdn = (m "net").networking.domain;
      };
      expected = {
        # md5("net")
        hostId = "40fa73c9";
        domain = "example.org";
        noFqdn = null;
      };
    };

    # the builder trusts its own cache with the key its metadata announces
    testBuilderKey = {
      expr = (cfg "alpha").fleet.builder.cache.publicKey;
      expected = "ftl-test-1:6CA2VCkcTQDS8JL6HcoXOOHZWCqjV+3baLKM86c7dcw=";
    };

    # comin follows the fleet's repository, at fleet.comin.branch
    testCominRemote = {
      expr =
        let
          c =
            (ftl.lib.mkNixos {
              inherit nixpkgs;
              repo = "github:example/fleet";
              sharedModules = [ comin.nixosModules.comin ];
              hosts.h.modules = [
                {
                  services.comin.enable = true;
                  fleet.comin.branch = "master";
                }
              ];
            }).nixosConfigurations.h.config;
        in
        map (r: {
          inherit (r) name url;
          branch = r.branches.main.name;
        }) c.services.comin.remotes;
      expected = [
        {
          name = "origin";
          url = "https://github.com/example/fleet.git";
          branch = "master";
        }
      ];
    };

    # git fetches the repository: a flake reference becomes its git URL
    testRepoUrl = {
      expr =
        let
          # the fixture's hosts set their own fleet.layers.repo
          bare =
            (ftl.lib.mkNixos {
              inherit nixpkgs;
              repo = "github:example/fleet";
              hosts.h = { };
            }).nixosConfigurations.h.config;
        in
        {
          layers = bare.fleet.layers.repo;
          client = bare.fleet.client.repo;
          meta = bare.fleet.meta.repo;
          github = gitUrl "github:o/r/main";
          gitlab = gitUrl "gitlab:o/r?ref=main";
          sourcehut = gitUrl "sourcehut:~o/r";
          gitPlus = gitUrl "git+https://git.example.org/r.git?ref=main";
          gitSsh = gitUrl "git+ssh://git@git.example.org/r.git";
          plain = gitUrl "https://git.example.org/r.git";
          scp = gitUrl "git@github.com:o/r.git";
          enterprise = gitUrl "github:o/r?host=git.example.com";
          subgroup = gitUrl "gitlab:group%2Fsub/r";
          malformed = (builtins.tryEval (gitUrl "github:o")).success;
        };
      expected = {
        layers = "https://github.com/example/fleet.git";
        client = "https://github.com/example/fleet.git";
        meta = "github:example/fleet";
        github = "https://github.com/o/r.git";
        gitlab = "https://gitlab.com/o/r.git";
        sourcehut = "https://git.sr.ht/~o/r";
        gitPlus = "https://git.example.org/r.git";
        gitSsh = "ssh://git@git.example.org/r.git";
        plain = "https://git.example.org/r.git";
        scp = "git@github.com:o/r.git";
        enterprise = "https://git.example.com/o/r.git";
        subgroup = "https://gitlab.com/group/sub/r.git";
        malformed = false;
      };
    };
  }
)
