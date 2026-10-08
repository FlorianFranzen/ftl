# mkHome, called directly (home-manager stubbed).
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
  h = ftl.lib.mkHome {
    src = fixture + "/home";
    inherit lib;
    pkgsFor = system: import nixpkgs { inherit system; };
    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    homeManager = hmStub;
    bases = {
      terminal = [ "terminal" ];
      desktop = [
        "terminal"
        "desktop"
      ];
    };
    extraSpecialArgs = { inherit static; };
    username = "alice";
  };
  cfg = system: name: h.configurations.${system}.${name}.config.home;
  names = [
    "desktop-dark"
    "desktop-default"
    "terminal-dark"
    "terminal-default"
  ];
in
check "unit-home" (
  lib.runTests {
    testNames = {
      expr = builtins.attrNames h.modules;
      expected = names;
    };

    # a base includes only the direct files of its profile dirs
    testDirectFilesOnly = {
      expr = builtins.attrNames (cfg "x86_64-linux" "desktop-dark").file;
      expected = [
        "common"
        "desktop"
        "shell"
        "variant"
      ];
    };

    testVariant = {
      expr = (cfg "x86_64-linux" "terminal-default").file.variant.text;
      expected = "default";
    };

    testPerSystem = {
      expr = builtins.mapAttrs (_: builtins.attrNames) h.configurations;
      expected = {
        x86_64-linux = names;
        aarch64-linux = names;
      };
    };

    testUsernameDefaults = {
      expr = {
        inherit (cfg "aarch64-linux" "terminal-dark") username homeDirectory;
      };
      expected = {
        username = "alice";
        homeDirectory = "/home/alice";
      };
    };

    # home/modules is shared into every configuration and receives `static`
    testStatic = {
      expr = (cfg "x86_64-linux" "terminal-dark").file.common.source;
      expected = static.wallpapers.dark;
    };

    testTrees = {
      expr = {
        modules = builtins.attrNames h.homeModules;
        profiles = builtins.attrNames h.homeProfiles;
      };
      expected = {
        modules = [ "common" ];
        profiles = [
          "desktop"
          "terminal"
        ];
      };
    };

    testChecks = {
      expr = builtins.attrNames h.checks.aarch64-linux;
      expected = map (n: "home-${n}") names;
    };
  }
)
