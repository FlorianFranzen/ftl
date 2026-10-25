# mkNixos, called directly.
{
  lib,
  ftl,
  nixpkgs,
  fixture,
  home-manager,
  sops-nix,
  comin,
  check,
  ...
}:
let
  static = ftl.lib.mkStatic { src = fixture + "/static"; };
  packages = ftl.lib.mkPackages {
    src = fixture + "/pkgs";
    inherit nixpkgs;
  };

  n = ftl.lib.mkNixos {
    src = fixture + "/nixos";
    root = fixture;
    inherit nixpkgs static;
    name = "unit";
    inherit (packages) pkgsFor;
    sharedModules = [
      home-manager.nixosModules.home-manager
      sops-nix.nixosModules.sops
      {
        nixpkgs.overlays = packages.overlays;
        nixpkgs.config = packages.config;
      }
    ];
    extraProfiles = {
      # local nixos/profiles wins over extra profiles of the same name
      base.common = {
        environment.etc."profile-source".text = "extra";
      };
      extra.only = {
        environment.etc."extra-only".text = "extra";
      };
    };
    # stand-ins for home configurations (home-manager wants a stateVersion)
    homes = {
      desktop-dark.home.stateVersion = "26.05";
      terminal-dark.home.stateVersion = "26.05";
    };
    homeCompanions.desktop-dark = [ { environment.etc."desktop-companion".text = "stub"; } ];
    users =
      (ftl.lib.mkUsers {
        src = fixture + "/users";
        inherit lib;
      }).users;
  };

  cfg = host: n.nixosConfigurations.${host}.config;
  failsWith =
    hosts:
    !(builtins.tryEval (
      builtins.attrNames
        (ftl.lib.mkNixos {
          inherit nixpkgs hosts;
        }).nixosConfigurations
    )).success;
in
check "unit-nixos" (
  lib.runTests {
    testHosts = {
      expr = builtins.attrNames n.nixosConfigurations;
      expected = [
        "alpha"
        "beta"
        "gamma"
      ];
    };

    # host.nix is metadata (importing it as a module would fail evaluation)
    testHostMeta = {
      expr = builtins.mapAttrs (_: h: { inherit (h) system importance layers; }) n.hosts;
      expected = {
        alpha = {
          system = "x86_64-linux";
          importance = "required";
          layers = [
            "tools"
            "svc"
          ];
        };
        beta = {
          system = "aarch64-linux";
          importance = "optional";
          layers = [ "tools" ];
        };
        gamma = {
          system = "x86_64-linux";
          importance = "required";
          # from its service (mesh)
          layers = [ "tools" ];
        };
      };
    };

    # free-form host.nix attributes become peer data, reserved ones are not repeated
    testPeers = {
      expr = n.fleet.hosts;
      expected = {
        alpha = {
          name = "alpha";
          system = "x86_64-linux";
          importance = "required";
          layers = [
            "tools"
            "svc"
          ];
          services = [
            "mesh"
            "web"
          ];
          users = [
            "alice"
            "bob"
          ];
          generators = [ "host-keys" ];
          keys = {
            ssh = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO7pFvyv5FcmP7vj/Q0OeeOBecLE9K/75Qch2uR6eRSl";
            initrd = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKODezmkKcdWZ4strBZey4HXGUlIdwQZ5CtDzbAzqvMZ";
          };
          fqdn = "alpha.example.org";
          roles = [ "web" ];
          smartcard = null;
        };
        beta = {
          name = "beta";
          system = "aarch64-linux";
          importance = "optional";
          layers = [ "tools" ];
          services = [ "mesh" ];
          users = [ "alice" ];
          generators = [ "host-keys" ];
          keys.age = "age1880pyzlyypv0cmec6e3tgwww9tgum9cywqn5743flkdz6krlxy2sksedxt";
          smartcard = {
            presence = "headless";
            readers.builder = {
              vendor = "1050";
              product = "0407";
              port = "1-4";
              serial = null;
              description = null;
            };
          };
        };
        gamma = {
          name = "gamma";
          system = "x86_64-linux";
          importance = "required";
          layers = [ "tools" ];
          services = [ "mesh" ];
          users = [ "alice" ];
          generators = [ "host-keys" ];
          smartcard = null;
        };
      };
    };

    # ftl's generators and the repository's, what they make
    testGenerators = {
      expr = {
        names = builtins.attrNames n.generators;
        token = n.generators.token.files;
        identity = builtins.attrNames (
          lib.filterAttrs (_: f: f.store or "" == "identity") n.generators.host-keys.files
        );
        # scope and inputs: a fleet generator runs once, a host generator may
        # read fleet files and other host generators' files
        scopes = lib.mapAttrs (_: g: g.scope) n.generators;
        certInputs = n.generators.cert.inputs;
      };
      expected = {
        names = [
          "age-key"
          "ca"
          "cert"
          "fleet-ca"
          "host-keys"
          "host-tls"
          "token"
          "wireguard"
        ];
        token = {
          "token.pub" = { };
          secret.secret = true;
        };
        identity = [
          "initrd_ssh_host_ed25519_key"
          "ssh_host_ed25519_key"
        ];
        scopes = {
          age-key = "host";
          ca = "fleet";
          cert = "host";
          fleet-ca = "fleet";
          host-keys = "host";
          host-tls = "host";
          token = "host";
          wireguard = "host";
        };
        certInputs = [
          "ca/ca.pub"
          "ca/ca.key"
          "host-keys/ssh.pub"
        ];
      };
    };
    testUndefinedGenerator = {
      expr =
        !(builtins.tryEval (
          builtins.attrNames
            (ftl.lib.mkNixos {
              inherit nixpkgs;
              hosts.delta.generators = [ "nope" ];
            }).hosts
        )).success;
      expected = true;
    };
    # a host lists host generators only; the fleet's run once
    testFleetGeneratorOnHost = {
      expr =
        !(builtins.tryEval (
          builtins.attrNames
            (ftl.lib.mkNixos {
              inherit nixpkgs;
              src = fixture + "/nixos";
              hosts.alpha.generators = [ "ca" ];
            }).hosts
        )).success;
      expected = true;
    };
    # inputs must exist, be declared, not loop, and a fleet generator reads
    # no host's files
    testGeneratorInputs = {
      expr =
        let
          g =
            (ftl.lib.mkNixos {
              inherit nixpkgs;
              src = ./../fixtures/generators/nixos;
            }).generators;
          ok = name: (builtins.tryEval (builtins.deepSeq g.${name} true)).success;
        in
        lib.genAttrs [
          "fine"
          "loop"
          "orphan"
          "undeclared"
          "fleet-of-host"
          "cycle-a"
          "cycle-b"
        ] ok;
      expected = {
        fine = true;
        loop = false;
        orphan = false;
        undeclared = false;
        fleet-of-host = false;
        cycle-a = false;
        cycle-b = false;
      };
    };
    # the fleet's own public files, nixos/<name>.pub
    testFleetKeys = {
      expr = {
        out = n.keys;
        arg = (cfg "alpha")._module.args.fleet.keys or n.fleet.keys;
      };
      expected =
        let
          keys = {
            example = "example-public-value";
            # a PEM file is kept whole, not cut to its first line
            pem = "-----BEGIN CERTIFICATE-----\nMIIBfixture\n-----END CERTIFICATE-----\n";
          };
        in
        {
          out = keys;
          arg = keys;
        };
    };

    # service.nix is metadata: hosts (or roles), layers, free-form data
    testServices = {
      expr = n.services;
      expected = {
        web = {
          name = "web";
          hosts = [ "alpha" ];
          roles.default.hosts = [ "alpha" ];
          layers = [ ];
          port = 8080;
          cache.publicKeys = [ "ftl-test-1:6CA2VCkcTQDS8JL6HcoXOOHZWCqjV+3baLKM86c7dcw=" ];
        };
        mesh = {
          name = "mesh";
          hosts = [
            "alpha"
            "beta"
            "gamma"
          ];
          roles = {
            hub.hosts = [ "alpha" ];
            spoke.hosts = [
              "beta"
              "gamma"
            ];
          };
          layers = [ "tools" ];
        };
      };
    };

    # a service's modules are imported on its hosts only, with the `service`
    # argument: its metadata and the host's roles in it
    testServiceModules = {
      expr = {
        alphaWeb = (cfg "alpha").environment.etc."service-web".text;
        alphaMesh = (cfg "alpha").environment.etc."service-mesh".text;
        betaMesh = (cfg "beta").environment.etc."service-mesh".text;
        betaWeb = (cfg "beta").environment.etc ? "service-web";
        meta = (cfg "gamma").fleet.meta.services;
      };
      expected = {
        alphaWeb = "web:8080:alpha:mesh,web";
        alphaMesh = "hub:beta,gamma";
        betaMesh = "spoke:beta,gamma";
        betaWeb = false;
        meta = [ "mesh" ];
      };
    };

    # a service's layers are installed on its hosts
    testServiceLayers = {
      expr = (cfg "gamma").fleet.layers.installed;
      expected.tools.kind = "packages";
    };

    # users: an admin is on every host, bob where his service is
    testUsers = {
      expr = lib.mapAttrs (_: u: {
        inherit (u) admin hosts;
      }) n.users;
      expected = {
        alice = {
          admin = true;
          hosts = [
            "alpha"
            "beta"
            "gamma"
          ];
        };
        bob = {
          admin = false;
          hosts = [ "alpha" ];
        };
      };
    };

    # fleet.access: accounts from the users, keys only, sudo via the agent,
    # every host key known
    testAccess = {
      expr =
        let
          a = cfg "alpha";
          b = cfg "beta";
        in
        {
          accounts = builtins.attrNames (lib.filterAttrs (_: u: u.isNormalUser) a.users.users);
          betaAccounts = builtins.attrNames (lib.filterAttrs (_: u: u.isNormalUser) b.users.users);
          alice = {
            inherit (a.users.users.alice) uid extraGroups;
            keys = a.users.users.alice.openssh.authorizedKeys.keys;
          };
          bobGroups = a.users.users.bob.extraGroups;
          mutable = a.users.mutableUsers;
          sshd = {
            inherit (a.services.openssh.settings) PasswordAuthentication PermitRootLogin;
          };
          sudo = a.security.pam.rssh.enable && a.security.pam.services.sudo.rssh;
          known = lib.mapAttrs (_: k: k.hostNames) (
            lib.filterAttrs (n: _: lib.hasPrefix "alpha" n) b.programs.ssh.knownHosts
          );
          home = b.home-manager.users ? alice;
          # bob's home is per host: alpha has one, no `default` for others
          bobHome = builtins.attrNames a.home-manager.users;
        };
      expected = {
        accounts = [
          "alice"
          "bob"
        ];
        betaAccounts = [ "alice" ];
        alice = {
          uid = 1000;
          extraGroups = [ "wheel" ];
          keys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHW437gdXlD8N84nBJqtbi36N1kia4RepapKRaxqlor6 alice"
          ];
        };
        bobGroups = [ "video" ];
        mutable = false;
        sshd = {
          PasswordAuthentication = false;
          PermitRootLogin = "no";
        };
        sudo = true;
        known = {
          alpha = [
            "alpha"
            "alpha.example.org"
          ];
          alpha-initrd = [
            "[alpha]:2222"
            "[alpha.example.org]:2222"
          ];
        };
        home = true;
        bobHome = [
          "alice"
          "bob"
        ];
      };
    };

    # alice's desktop home brings the desktop profile's NixOS side to her hosts
    testHomeCompanions = {
      expr = {
        alpha = (cfg "alpha").environment.etc ? "desktop-companion";
        gamma = (cfg "gamma").environment.etc ? "desktop-companion";
      };
      expected = {
        alpha = true;
        gamma = true;
      };
    };

    # a state entry whose unit runs as a user without a fixed uid fails
    testStateFloatingUid = {
      expr =
        let
          c =
            (ftl.lib.mkNixos {
              inherit nixpkgs;
              hosts.delta.modules = [
                {
                  fleet.storage.btrfsDevice = "/dev/vdb";
                  fleet.state.db = {
                    path = "/var/lib/db";
                    units = [ "db" ];
                  };
                  systemd.services.db.serviceConfig.User = "db";
                  users.users.db.isSystemUser = true;
                  users.users.db.group = "db";
                  users.groups.db = { };
                }
              ];
            }).nixosConfigurations.delta.config;
        in
        lib.filter (a: !a.assertion) c.assertions != [ ];
      expected = true;
    };

    # secrets: the host store through sops-nix, a service's through `service.sopsFile`
    testSecrets = {
      expr = {
        alpha = {
          file = (cfg "alpha").sops.defaultSopsFile;
          ageKey = (cfg "alpha").sops.age.keyFile;
          token = (cfg "alpha").sops.secrets."web/token".sopsFile;
        };
        # beta decrypts with a dedicated age key; gamma has no store (yet)
        betaAgeKey = (cfg "beta").sops.age.keyFile;
        gamma = (cfg "gamma").fleet.secrets.file;
      };
      expected = {
        alpha = {
          file = fixture + "/nixos/hosts/alpha/secrets.yaml";
          ageKey = null;
          token = fixture + "/nixos/services/web/secrets.yaml";
        };
        betaAgeKey = "/var/lib/sops-nix/key.txt";
        gamma = null;
      };
    };

    # every store with its recipients: hosts by SSH key (or age override),
    # users by their sops keys; stores nobody could read are left out
    testStores = {
      expr = map (s: {
        inherit (s) path kind;
        r = s.recipients;
      }) n.sops.stores;
      expected =
        let
          alice = "age18jlex7sq6yufhk48ljzs5uzxrtazqrchddanezf7w5gl48nccv7sflpg7l";
          alphaSsh = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO7pFvyv5FcmP7vj/Q0OeeOBecLE9K/75Qch2uR6eRSl";
          betaAge = "age1880pyzlyypv0cmec6e3tgwww9tgum9cywqn5743flkdz6krlxy2sksedxt";
          r = age: ssh: {
            pgp = [ ];
            inherit age ssh;
          };
        in
        [
          {
            path = "nixos/hosts/alpha/identity.yaml";
            kind = "identity";
            r = r [ alice ] [ ];
          }
          {
            path = "nixos/hosts/alpha/secrets.yaml";
            kind = "host";
            r = r [ alice ] [ alphaSsh ];
          }
          {
            path = "nixos/hosts/beta/identity.yaml";
            kind = "identity";
            r = r [ alice ] [ ];
          }
          {
            path = "nixos/hosts/beta/secrets.yaml";
            kind = "host";
            r = r [ alice betaAge ] [ ];
          }
          {
            path = "nixos/hosts/gamma/identity.yaml";
            kind = "identity";
            r = r [ alice ] [ ];
          }
          {
            path = "nixos/hosts/gamma/secrets.yaml";
            kind = "host";
            r = r [ alice ] [ ];
          }
          {
            path = "nixos/identity.yaml";
            kind = "fleet-identity";
            r = r [ alice ] [ ];
          }
          {
            path = "nixos/secrets.yaml";
            kind = "fleet";
            r = r [ alice betaAge ] [ alphaSsh ];
          }
          {
            path = "nixos/services/mesh/secrets.yaml";
            kind = "service";
            r = r [ alice betaAge ] [ alphaSsh ];
          }
          {
            path = "nixos/services/web/secrets.yaml";
            kind = "service";
            r = r [ alice ] [ alphaSsh ];
          }
          {
            path = "users/alice/secrets.yaml";
            kind = "user";
            r = r [ alice ] [ ];
          }
        ];
    };

    # fleet.state: a subvolume per entry, mounted by a mount unit its units wait for
    testState = {
      expr =
        let
          c = cfg "alpha";
          mount = lib.findFirst (m: m.where == "/var/lib/web") null c.systemd.mounts;
        in
        {
          locations = lib.mapAttrs (_: e: e.location) c.fleet.state;
          backup = lib.mapAttrs (_: e: e.backup) c.fleet.state;
          service = c.fleet.state.web.service;
          mount = {
            inherit (mount) what type options;
          };
          requires = c.systemd.services.web.unitConfig.RequiresMountsFor;
        };
      expected = {
        locations = {
          web = "@apps/web";
          web-cache = "@data/web-cache";
        };
        backup = {
          web = true;
          web-cache = false;
        };
        service = "web";
        mount = {
          what = "/dev/disk/by-label/root";
          type = "btrfs";
          options = "subvol=@apps/web,compress=zstd,noatime";
        };
        requires = [ "/var/lib/web" ];
      };
    };

    # nixosServices.<name> is the service as a module for any configuration;
    # roles come from that configuration's host name
    testServicesExport = {
      expr =
        let
          c =
            (ftl.lib.mkNixos {
              inherit nixpkgs;
              hosts = {
                delta.modules = [ n.nixosServices.mesh ];
                beta.modules = [ n.nixosServices.mesh ];
              };
            }).nixosConfigurations;
        in
        {
          delta = c.delta.config.environment.etc."service-mesh".text;
          beta = c.beta.config.environment.etc."service-mesh".text;
        };
      expected = {
        delta = ":beta,gamma";
        beta = "spoke:beta,gamma";
      };
    };

    testServiceUnknownHost = {
      expr =
        !(builtins.tryEval (
          builtins.attrNames
            (ftl.lib.mkNixos {
              inherit nixpkgs;
              hosts.delta = { };
              services.x.hosts = [ "nope" ];
            }).services
        )).success;
      expected = true;
    };

    # every host sees all hosts (itself included) as `fleet.hosts`, itself as
    # `fleet.self`, and can use them in imports
    testFleetArg = {
      expr =
        (ftl.lib.mkNixos {
          src = fixture + "/nixos";
          inherit nixpkgs;
          sharedModules = [ home-manager.nixosModules.home-manager ];
          hosts.gamma.modules = [
            (
              { fleet, lib, ... }:
              {
                imports = lib.optional (fleet.hosts ? alpha) {
                  environment.etc.peer.text = "${fleet.hosts.alpha.fqdn} ${fleet.self.name}";
                };
              }
            )
          ];
        }).nixosConfigurations.gamma.config.environment.etc.peer.text;
      expected = "alpha.example.org gamma";
    };

    # explicit host specs carry data too, and `name` is reserved
    testPeersExplicit = {
      expr =
        (ftl.lib.mkNixos {
          inherit nixpkgs;
          hosts.delta.address = "192.0.2.4";
        }).fleet.hosts.delta.address;
      expected = "192.0.2.4";
    };
    testPeersReservedName = {
      expr = failsWith { delta.name = "other"; };
      expected = true;
    };

    testModulesEverywhere = {
      expr = map (h: (cfg h).fixture.common) [
        "alpha"
        "beta"
        "gamma"
      ];
      expected = [
        true
        true
        true
      ];
    };

    testProfiles = {
      expr = {
        local = (cfg "alpha").environment.etc."profile-source".text;
        extra = (cfg "alpha").environment.etc."extra-only".text;
      };
      expected = {
        local = "local";
        extra = "extra";
      };
    };

    testStatic = {
      expr = (cfg "alpha").environment.etc.marker.source;
      expected = static.marker;
    };

    testLocalPackages = {
      expr = builtins.elem "hello-ftl" (map lib.getName (cfg "alpha").environment.systemPackages);
      expected = true;
    };

    testHostPlatform = {
      expr = (cfg "beta").nixpkgs.hostPlatform.system;
      expected = "aarch64-linux";
    };

    testLayers = {
      expr = builtins.mapAttrs (_: builtins.attrNames) n.nixosLayers;
      expected = {
        x86_64-linux = [
          "svc"
          "tools"
        ];
        aarch64-linux = [ "tools" ];
      };
    };

    testLayerWiring = {
      expr = (cfg "alpha").fleet.layers.installed;
      expected = {
        svc.kind = "units";
        tools.kind = "packages";
      };
    };

    # with comin's module imported and enabled, its post-deployment hook is ftl's
    testCominHook = {
      expr =
        let
          c =
            (ftl.lib.mkNixos {
              inherit nixpkgs;
              sharedModules = [ comin.nixosModules.comin ];
              hosts.delta.modules = [
                {
                  services.comin = {
                    enable = true;
                    remotes = [
                      {
                        name = "origin";
                        url = "https://example.org/fleet.git";
                        branches.main.name = "main";
                      }
                    ];
                  };
                }
              ];
            }).nixosConfigurations.delta.config;
        in
        c.fleet.comin.enable && c.services.comin.postDeploymentCommand == c.fleet.comin.hook;
      expected = true;
    };

    # a layer kind is packages or units
    testLayerKindInvalid = {
      expr =
        !(builtins.tryEval
          (ftl.lib.mkNixos {
            inherit nixpkgs;
            hosts.delta.layers = [ "old" ];
            layers.old = {
              kind = "apps";
              packages = [ ];
            };
          }).nixosConfigurations.delta.config.fleet.layers.installed.old.kind
        ).success;
      expected = true;
    };

    testCheckNames = {
      expr = builtins.mapAttrs (_: builtins.attrNames) n.checks;
      expected = {
        x86_64-linux = [
          "nixos-alpha"
          "nixos-gamma"
          "nixos-layer-svc"
          "nixos-layer-tools"
        ];
        aarch64-linux = [
          "nixos-beta"
          "nixos-layer-tools"
        ];
      };
    };

    testFleetArgs = {
      expr = n.nixosConfigurations.alpha.fleetArgs.specialArgs ? static;
      expected = true;
    };

    testLayerNameCollision = {
      expr = failsWith { layer-x = { }; };
      expected = true;
    };
    testUndefinedLayer = {
      expr = failsWith { a.layers = [ "nope" ]; };
      expected = true;
    };
  }
)
