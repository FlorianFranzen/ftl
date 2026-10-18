# All families together through mkFlake: cross-family wiring.
{
  pkgs,
  lib,
  ftl,
  fixture,
  inputs,
  check,
  ...
}:
let
  mk =
    extra:
    ftl.lib.mkFlake (
      {
        src = fixture;
        inherit inputs;
        name = "full";
        repo = "file:///fixture";
        nixos.extraProfiles.extra.only = {
          environment.etc."extra-only".text = "extra";
        };
        home = {
          bases = {
            terminal = [ "terminal" ];
            desktop = [
              "terminal"
              "desktop"
            ];
          };
          systems = [
            "x86_64-linux"
            "aarch64-linux"
          ];
          username = "alice";
        };
        # pass-through, deep-merged with the generated packages
        packages.x86_64-linux.extra = pkgs.emptyFile;
      }
      // extra
    );

  f = mk { };
  alpha = f.nixosConfigurations.alpha.config;
  homeNames = [
    "home-desktop-dark"
    "home-desktop-default"
    "home-terminal-dark"
    "home-terminal-default"
  ];
  succeeds = x: (builtins.tryEval x).success;
  pkgNamed = name: lib.findFirst (p: lib.getName p == name) null alpha.environment.systemPackages;
in
check "flake-full" (
  lib.runTests {
    testOutputs = {
      expr = builtins.attrNames f;
      expected = [
        "apps"
        "checks"
        "fleet"
        "ftlManifest"
        "ftlPeers"
        "homeConfigurations"
        "homeModules"
        "homeProfiles"
        "legacyPackages"
        "nixosConfigurations"
        "nixosLayers"
        "nixosModules"
        "nixosProfiles"
        "nixosServices"
        "overlays"
        "packages"
      ];
    };

    # pkgs/ overlay and config reach hosts and layers
    testOverlayInHost = {
      expr = pkgNamed "hello-ftl" != null;
      expected = true;
    };
    testConfigInHost = {
      expr = succeeds (pkgNamed "unfree-ftl").drvPath;
      expected = true;
    };
    testConfigInLayer = {
      expr = succeeds f.nixosLayers.x86_64-linux.tools.drvPath;
      expected = true;
    };

    # homes are wired into hosts, with shared home modules and `static`
    testHomesInHost = {
      expr = {
        variant = alpha.home-manager.evaluated.alice.home.file.variant.text;
        shared = alpha.home-manager.evaluated.alice.home.file.common.source;
      };
      expected = {
        variant = "dark";
        shared = fixture + "/static/wallpapers/dark.png";
      };
    };
    # the desktop profile's nixos.nix reaches a host through its user's home
    testHomeCompanionInHost = {
      expr = alpha.environment.etc."desktop-companion".text;
      expected = "from home/profiles/desktop";
    };
    testStaticInHost = {
      expr = alpha.environment.etc.marker.source;
      expected = fixture + "/static/marker.txt";
    };
    testStaticInHome = {
      expr = f.homeConfigurations.terminal-dark.config.home.file.common.source;
      expected = fixture + "/static/wallpapers/dark.png";
    };

    # flake integration module
    testIntegration = {
      expr = {
        revision = alpha.system.configurationRevision;
        registry = builtins.attrNames alpha.nix.registry;
        hm = { inherit (alpha.home-manager) useGlobalPkgs useUserPackages backupFileExtension; };
      };
      expected = {
        revision = "abc1234";
        registry = [
          "nixpkgs"
          "self"
        ];
        hm = {
          useGlobalPkgs = true;
          useUserPackages = true;
          backupFileExtension = "conflict";
        };
      };
    };

    testManifestKinds = {
      expr = lib.unique (
        lib.sort lib.lessThan (
          lib.concatMap (s: map (e: e.kind) (builtins.attrValues s)) (
            builtins.attrValues f.fleet.manifest.attrs
          )
        )
      );
      expected = [
        "home"
        "layer"
        "nixos"
      ];
    };

    testChecks = {
      expr = builtins.mapAttrs (_: builtins.attrNames) f.checks;
      expected = {
        x86_64-linux = [ "fleet-sops" ] ++ homeNames ++ [
          "nixos-alpha"
          "nixos-gamma"
          "nixos-layer-svc"
          "nixos-layer-tools"
        ];
        aarch64-linux = [ "fleet-sops" ] ++ homeNames ++ [
          "nixos-beta"
          "nixos-layer-tools"
        ];
      };
    };

    # the fleet output carries the host data and the manifest
    testFleetOutput = {
      expr = {
        names = builtins.attrNames f.fleet;
        alpha = f.fleet.hosts.alpha.fqdn;
      };
      expected = {
        names = [
          "hosts"
          "manifest"
          "services"
          "sops"
          "users"
        ];
        alpha = "alpha.example.org";
      };
    };

    testPassthru = {
      expr = builtins.attrNames f.packages.x86_64-linux;
      expected = [
        "extra"
        "fleetl"
        "hello-ftl"
        "unfree-ftl"
      ];
    };

    testLegacyHomes = {
      expr = builtins.attrNames f.legacyPackages.aarch64-linux.homeConfigurations;
      expected = map (lib.removePrefix "home-") homeNames;
    };

    # layout: renamed folder (unknown root folders are ignored otherwise)
    testRenamedFolder = {
      expr =
        (mk { layout.static = "alt-static"; })
        .nixosConfigurations.alpha.config.environment.etc.marker.source;
      expected = fixture + "/alt-static/marker.txt";
    };
  }
)
