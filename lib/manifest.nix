# Build the `fleet.manifest` output from a normalized host/home table.
#
# The manifest is the single contract between an environment repo and the
# ftl pipeline: a plain, JSON-serializable attrset mapping every check
# attribute to its origin and importance. Tooling must never parse attribute
# names; everything it needs is spelled out here.
{
  name,
  repo ? null,
  # entries: list of {
  #   checkName, kind ("nixos"|"layer"|"home"), host (or null), layer (or null),
  #   system, importance ("required"|"optional"|"ignored"), configAttr
  # }
  entries,
}:
let
  bySystem = builtins.groupBy (e: e.system) entries;
in
{
  inherit name repo;
  version = 1;
  attrs = builtins.mapAttrs (
    system: es:
    builtins.listToAttrs (
      map (e: {
        name = e.checkName;
        value = {
          inherit (e)
            kind
            host
            layer
            system
            importance
            configAttr
            ;
          flakeAttr = "checks.${system}.${e.checkName}";
        };
      }) es
    )
  ) bySystem;
}
