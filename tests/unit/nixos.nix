# mkNixos, called directly.
{
  lib,
  ftl,
  nixpkgs,
  fixture,
  hmStub,
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
    inherit nixpkgs static;
    name = "unit";
    inherit (packages) pkgsFor;
    sharedModules = [
      hmStub.nixosModules.home-manager
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
    homes.desktop-dark = { };
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
      expr = n.peers;
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
          fqdn = "alpha.example.org";
          roles = [ "web" ];
        };
        beta = {
          name = "beta";
          system = "aarch64-linux";
          importance = "optional";
          layers = [ "tools" ];
          services = [ "mesh" ];
        };
        gamma = {
          name = "gamma";
          system = "x86_64-linux";
          importance = "required";
          layers = [ "tools" ];
          services = [ "mesh" ];
        };
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
    # `fleet.self`, and can use them in imports; `peers` is the old name
    testFleetArg = {
      expr =
        (ftl.lib.mkNixos {
          src = fixture + "/nixos";
          inherit nixpkgs;
          sharedModules = [ hmStub.nixosModules.home-manager ];
          hosts.gamma.modules = [
            (
              {
                fleet,
                peers,
                lib,
                ...
              }:
              {
                imports = lib.optional (fleet.hosts ? alpha) {
                  environment.etc.peer.text = "${fleet.hosts.alpha.fqdn} ${fleet.self.name} ${peers.alpha.fqdn}";
                };
              }
            )
          ];
        }).nixosConfigurations.gamma.config.environment.etc.peer.text;
      expected = "alpha.example.org gamma alpha.example.org";
    };

    # explicit host specs carry data too, and `name` is reserved
    testPeersExplicit = {
      expr =
        (ftl.lib.mkNixos {
          inherit nixpkgs;
          hosts.delta.address = "192.0.2.4";
        }).peers.delta.address;
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

    # the old option names still work, with a warning
    testOptionAliases = {
      expr =
        let
          c =
            (ftl.lib.mkNixos {
              inherit nixpkgs;
              hosts.delta.modules = [
                {
                  ftl.layers.repo = "file:///old-name";
                  ftl.client.gc.dates = "monthly";
                }
              ];
            }).nixosConfigurations.delta.config;
        in
        {
          repo = c.fleet.layers.repo;
          dates = c.fleet.client.gc.dates;
          warned = builtins.length c.warnings;
        };
      expected = {
        repo = "file:///old-name";
        dates = "monthly";
        warned = 1;
      };
    };

    # the old kind names of layers are accepted, and normalized
    testLayerKindAliases = {
      expr =
        (ftl.lib.mkNixos {
          inherit nixpkgs;
          hosts.delta.layers = [ "old" ];
          layers.old = {
            kind = "apps";
            packages = [ ];
          };
        }).nixosConfigurations.delta.config.fleet.layers.installed.old.kind;
      expected = "packages";
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
