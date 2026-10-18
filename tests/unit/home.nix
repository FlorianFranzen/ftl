# mkHome, called directly (home-manager stubbed).
{
  lib,
  ftl,
  nixpkgs,
  fixture,
  home-manager,
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
    homeManager = home-manager;
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
    # a profile dir's nixos.nix is not a home module; it is the configuration's companion
    testCompanions = {
      expr = {
        companions = h.companions.desktop-dark;
        terminal = h.companions.terminal-dark;
      };
      expected = {
        companions = [ (fixture + "/home/profiles/desktop/nixos.nix") ];
        terminal = [ ];
      };
    };

    testNames = {
      expr = builtins.attrNames h.modules;
      expected = names;
    };

    # a base includes only the direct files of its profile dirs
    # the fixture's files (home-manager adds a few of its own); nothing from
    # desktop/light, a subdirectory of a listed dir
    testDirectFilesOnly = {
      expr = lib.filter (n: !lib.hasPrefix "/" n) (builtins.attrNames (cfg "x86_64-linux" "desktop-dark").file);
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
