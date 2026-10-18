# Layer kinds, and the names they had before fleet services existed.
lib:
let
  renamed = {
    apps = "packages";
    services = "units";
  };
in
rec {
  current = [
    "packages"
    "units"
  ];
  all = current ++ builtins.attrNames renamed;

  # Old name -> new name, with a warning; unknown kinds fail.
  normalize =
    what: kind:
    if builtins.elem kind current then
      kind
    else if renamed ? ${kind} then
      lib.warn "ftl: ${what}: layer kind \"${kind}\" is called \"${renamed.${kind}}\" now" renamed.${kind}
    else
      throw "ftl: ${what} has invalid layer kind '${kind}'";
}
