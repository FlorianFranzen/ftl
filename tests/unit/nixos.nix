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
  failsWith = hosts: !(builtins.tryEval (builtins.attrNames (ftl.lib.mkNixos {
    inherit nixpkgs hosts;
  }).nixosConfigurations)).success;
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
          layers = [ ];
        };
      };
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
      expr = (cfg "alpha").ftl.layers.installed;
      expected = {
        svc.kind = "services";
        tools.kind = "apps";
      };
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

    testFtlArgs = {
      expr = n.nixosConfigurations.alpha.ftlArgs.specialArgs ? static;
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
