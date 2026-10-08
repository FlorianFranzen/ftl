# mkStatic, called directly.
{
  lib,
  ftl,
  fixture,
  check,
  ...
}:
let
  static = ftl.lib.mkStatic { src = fixture + "/static"; };
  keys = s: builtins.attrNames (builtins.removeAttrs s [ "outPath" ]);
in
check "unit-static" (
  lib.runTests {
    testKeys = {
      expr = keys static;
      expected = [
        "emacs"
        "marker"
        "wallpapers"
      ];
    };

    # extension stripped, nesting follows directories
    testFile = {
      expr = static.wallpapers.dark;
      expected = fixture + "/static/wallpapers/dark.png";
    };

    # a directory is usable as a path and keeps its children
    testDirOutPath = {
      expr = static.emacs.outPath;
      expected = fixture + "/static/emacs";
    };
    testDirChildren = {
      expr = keys static.emacs;
      expected = [
        "config"
        "init"
      ];
    };
    testDirIsPathType = {
      expr = lib.types.path.check static.emacs;
      expected = true;
    };
    # same store path as the equivalent path literal
    testDirStorePath = {
      expr = "${static.emacs}" == "${fixture + "/static/emacs"}";
      expected = true;
    };

    testAmbiguousNames = {
      expr = (builtins.tryEval (builtins.attrNames (ftl.lib.mkStatic { src = ../fixtures/static-dupes; }))).success;
      expected = false;
    };
  }
)
