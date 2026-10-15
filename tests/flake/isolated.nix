# Each family through mkFlake in isolation: all other folders disabled.
{
  lib,
  ftl,
  fixture,
  inputs,
  check,
  ...
}:
let
  families = [
    "pkgs"
    "nixos"
    "home"
    "static"
  ];
  only =
    family:
    ftl.lib.mkFlake {
      src = fixture;
      inherit inputs;
      name = "isolated";
      layout = lib.genAttrs families (f: if f == family then f else null);
      home.bases.terminal = [ "terminal" ];
    };
  outputs = family: builtins.attrNames (only family);
in
check "flake-isolated" (
  lib.runTests {
    testPkgsOnly = {
      expr = outputs "pkgs";
      expected = [
        "ftlManifest"
        "legacyPackages"
        "overlays"
        "packages"
      ];
    };

    testNixosOnly = {
      expr = outputs "nixos";
      expected = [
        "checks"
        "ftlManifest"
        "ftlPeers"
        "nixosConfigurations"
        "nixosLayers"
        "nixosModules"
        "nixosProfiles"
      ];
    };
    # a host needing nothing from the other folders still evaluates
    testNixosOnlyEval = {
      expr = (only "nixos").nixosConfigurations.gamma.config.fixture.common;
      expected = true;
    };

    testHomeOnly = {
      expr = outputs "home";
      expected = [
        "checks"
        "ftlManifest"
        "homeConfigurations"
        "homeModules"
        "homeProfiles"
        "legacyPackages"
      ];
    };
    # without pkgs/, legacyPackages only carries the home configurations
    testHomeOnlyLegacy = {
      expr = builtins.attrNames (only "home").legacyPackages.x86_64-linux;
      expected = [ "homeConfigurations" ];
    };

    # static/ produces no outputs of its own
    testStaticOnly = {
      expr = outputs "static";
      expected = [ "ftlManifest" ];
    };

    testManifestPerFamily = {
      expr = lib.genAttrs families (
        f:
        lib.unique (
          lib.sort lib.lessThan (
            lib.concatMap (s: map (e: e.kind) (builtins.attrValues s)) (
              builtins.attrValues (only f).ftlManifest.attrs
            )
          )
        )
      );
      expected = {
        pkgs = [ ];
        nixos = [
          "layer"
          "nixos"
        ];
        home = [ "home" ];
        static = [ ];
      };
    };
  }
)
