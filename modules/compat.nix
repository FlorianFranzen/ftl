# ftl.* -> fleet.*: the NixOS options were renamed with the fleet additions.
# Every option below `fleet` is mirrored below `ftl`, and definitions made
# there are forwarded, with one warning. Remove with the next release.
{
  lib,
  options,
  ...
}:
let
  # Read-only options (hooks) cannot be set anyway, and forwarding an alias
  # into one counts as a second definition, so they have no mirror.
  mirror =
    tree:
    lib.concatMapAttrs (
      n: v:
      if lib.isOption v then
        lib.optionalAttrs (!(v.readOnly or false)) {
          ${n} = lib.mkOption {
            type = v.type;
            visible = false;
          };
        }
      else
        { ${n} = mirror v; }
    ) tree;

  forward =
    from: tree:
    lib.concatMapAttrs (
      n: v:
      if lib.isOption v then
        lib.optionalAttrs (!(v.readOnly or false)) { ${n} = lib.mkAliasDefinitions from.${n}; }
      else
        { ${n} = forward from.${n} v; }
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
