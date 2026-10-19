# Layer kinds: packages (added to environment.profiles) and units (unit files
# linked in by a systemd generator).
lib: rec {
  all = [
    "packages"
    "units"
  ];

  check =
    what: kind:
    if builtins.elem kind all then kind else throw "ftl: ${what} has invalid layer kind '${kind}'";
}
