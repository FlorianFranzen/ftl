# loadTree: directory -> nested attrset of .nix file paths.
#
#   foo.nix  -> foo = <path>
#   bar/     -> bar = { ... }   (recursively; empty results are dropped)
#
# Non-.nix files and names listed in `exclude` (top level only) are ignored.
# default.nix is NOT special: it becomes an entry named `default`.
let
  loadTree =
    {
      dir,
      exclude ? [ ],
    }:
    let
      entries = builtins.readDir dir;
      names = builtins.filter (n: !(builtins.elem n exclude)) (builtins.attrNames entries);
      toEntry =
        name:
        let
          type = entries.${name};
          path = dir + "/${name}";
          sub = loadTree { dir = path; };
        in
        if type == "directory" then
          if sub == { } then
            null
          else
            {
              inherit name;
              value = sub;
            }
        else if builtins.match ".+\\.nix" name != null then
          {
            name = builtins.substring 0 (builtins.stringLength name - 4) name;
            value = path;
          }
        else
          null;
    in
    builtins.listToAttrs (builtins.filter (e: e != null) (map toEntry names));

  # loadTree, or { } when the directory does not exist.
  loadTreeIfExists =
    args: if args.dir != null && builtins.pathExists args.dir then loadTree args else { };

  # All paths of a tree, depth first in attribute-name order.
  collectPaths =
    tree:
    builtins.concatMap (v: if builtins.isAttrs v then collectPaths v else [ v ]) (
      builtins.attrValues tree
    );
in
{
  inherit loadTree loadTreeIfExists collectPaths;
}
