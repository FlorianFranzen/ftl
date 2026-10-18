# ftl.* -> fleet.*: the NixOS options were renamed with the fleet additions.
# Every option below `fleet` is mirrored below `ftl`, and definitions made
# there are forwarded, with one warning. Remove with the next release.
{
  lib,
  options,
  ...
}:
let
  mirror =
    tree:
    lib.mapAttrs (
      _: v:
      if lib.isOption v then
        lib.mkOption {
          type = v.type;
          visible = false;
        }
      else
        mirror v
    ) tree;

  forward =
    from: tree:
    lib.mapAttrs (
      n: v: if lib.isOption v then lib.mkAliasDefinitions from.${n} else forward from.${n} v
    ) tree;

  defined =
    tree: lib.any (v: if lib.isOption v then v.isDefined else defined v) (builtins.attrValues tree);
in
{
  options.ftl = mirror options.fleet;

  config = {
    fleet = forward options.ftl options.fleet;
    warnings = lib.optional (defined options.ftl) "ftl: the `ftl.*` options are called `fleet.*` now";
  };
}
