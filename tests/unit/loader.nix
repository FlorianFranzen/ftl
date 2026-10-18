# loadTree / collectPaths, called directly.
{
  lib,
  ftl,
  fixture,
  check,
  ...
}:
let
  inherit (ftl.lib) loadTree collectPaths;
  profiles = fixture + "/home/profiles";
in
check "unit-loader" (
  lib.runTests {
    # non-.nix files and excluded names are ignored
    testHostDir = {
      expr = loadTree {
        dir = fixture + "/nixos/hosts/alpha";
        exclude = [ "host.nix" ];
      };
      expected = {
        config = fixture + "/nixos/hosts/alpha/config.nix";
      };
    };

    testNested = {
      expr = loadTree { dir = profiles; };
      expected = {
        desktop = {
          desktop = profiles + "/desktop/desktop.nix";
          light.light = profiles + "/desktop/light/light.nix";
          nixos = profiles + "/desktop/nixos.nix";
        };
        terminal.shell = profiles + "/terminal/shell.nix";
      };
    };

    # default.nix is an ordinary entry (haumea behaviour)
    testDefaultNotSpecial = {
      expr = builtins.attrNames (loadTree { dir = fixture + "/home/variants"; });
      expected = [
        "dark"
        "default"
      ];
    };

    testCollectPaths = {
      expr = collectPaths (loadTree { dir = profiles; });
      expected = [
        (profiles + "/desktop/desktop.nix")
        (profiles + "/desktop/light/light.nix")
        (profiles + "/desktop/nixos.nix")
        (profiles + "/terminal/shell.nix")
      ];
    };
  }
)
