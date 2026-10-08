# mkStatic: static/ folder -> lookup tree of files for use in Nix code.
#
#   static/wallpapers/nixish-dark.png -> static.wallpapers.nixish-dark
#   static/emacs/                     -> static.emacs (usable as a path via
#                                        its outPath; children stay reachable)
#
# Keys are file names without their last extension. ftl installs nothing:
# user code decides where a file goes. Ambiguous names (e.g. foo.png next to
# foo.jpg) and a file called "outPath" are evaluation errors.
{ src }:
let
  stripExt =
    name:
    let
      m = builtins.match "(.+)\\.[^.]+" name;
    in
    if m == null then name else builtins.head m;

  go =
    dir:
    let
      entries = builtins.readDir dir;
      children = map (
        file:
        let
          isDir = entries.${file} == "directory";
        in
        {
          name = if isDir then file else stripExt file;
          value = if isDir then go (dir + "/${file}") else dir + "/${file}";
        }
      ) (builtins.attrNames entries);
      keys = map (c: c.name) children;
      dupes = builtins.filter (k: builtins.length (builtins.filter (x: x == k) keys) > 1) keys;
    in
    if dupes != [ ] then
      throw "ftl: static: ambiguous names in ${toString dir}: ${toString dupes}"
    else if builtins.elem "outPath" keys then
      throw "ftl: static: ${toString dir} contains a file named outPath"
    else
      builtins.listToAttrs children // { outPath = dir; };
in
go src
