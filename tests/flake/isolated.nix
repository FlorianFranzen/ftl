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
    "users"
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
        "fleet"
        "legacyPackages"
        "overlays"
        "packages"
      ];
    };

    testNixosOnly = {
      expr = outputs "nixos";
      expected = [
        "apps"
        "checks"
        "devShells"
        "fleet"
        "nixosConfigurations"
        "nixosLayers"
        "nixosModules"
        "nixosProfiles"
        "nixosServices"
        "packages"
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
        "fleet"
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

    # static/ and users/ produce no outputs of their own
    testStaticOnly = {
      expr = outputs "static";
      expected = [ "fleet" ];
    };
    testUsersOnly = {
      expr = outputs "users";
      expected = [ "fleet" ];
    };

    testManifestPerFamily = {
      expr = lib.genAttrs families (
        f:
        lib.unique (
          lib.sort lib.lessThan (
            lib.concatMap (s: map (e: e.kind) (builtins.attrValues s)) (
              builtins.attrValues (only f).fleet.manifest.attrs
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
        users = [ ];
      };
    };
  }
)
