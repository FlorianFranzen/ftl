# mkPackages, called directly.
{
  lib,
  ftl,
  nixpkgs,
  fixture,
  check,
  ...
}:
let
  p = ftl.lib.mkPackages {
    src = fixture + "/pkgs";
    inherit nixpkgs;
  };
  succeeds = x: (builtins.tryEval x).success;
in
check "unit-packages" (
  lib.runTests {
    # only <name>/package.nix dirs are top-level packages (not group/)
    testNames = {
      expr = p.packageNames;
      expected = [
        "arm-only"
        "hello-ftl"
        "mkHelper"
        "unfree-ftl"
      ];
    };

    # helper functions are in the package set but not in packages.<system>
    testHelperFunction = {
      expr = {
        inPkgs = lib.isFunction p.pkgs.x86_64-linux.mkHelper;
        inPackages = p.packages.x86_64-linux ? mkHelper;
      };
      expected = {
        inPkgs = true;
        inPackages = false;
      };
    };

    # packages.<system> only lists packages available on that system
    testAvailability = {
      expr = builtins.mapAttrs (_: builtins.attrNames) p.packages;
      expected = {
        x86_64-linux = [
          "hello-ftl"
          "unfree-ftl"
        ];
        aarch64-linux = [
          "arm-only"
          "hello-ftl"
          "unfree-ftl"
        ];
      };
    };

    # overlay.nix overrides existing packages and wires free-form dirs
    testOverride = {
      expr = p.pkgs.x86_64-linux.hello.ftlOverridden;
      expected = true;
    };
    testGrouped = {
      expr = {
        inPkgs = p.pkgs.x86_64-linux ? grouped;
        inPackages = p.packages.x86_64-linux ? grouped;
      };
      expected = {
        inPkgs = true;
        inPackages = false;
      };
    };

    # config.nix allows the unfree package; an explicit config replaces it
    testConfig = {
      expr = succeeds p.pkgs.x86_64-linux.unfree-ftl.drvPath;
      expected = true;
    };
    testExplicitConfig = {
      expr = succeeds
        (ftl.lib.mkPackages {
          src = fixture + "/pkgs";
          inherit nixpkgs;
          config = { };
        }).pkgs.x86_64-linux.unfree-ftl.drvPath;
      expected = false;
    };

    # pkgsFor also works for systems outside `systems`
    testPkgsFor = {
      expr = (p.pkgsFor "riscv64-linux").stdenv.hostPlatform.system;
      expected = "riscv64-linux";
    };
  }
)
