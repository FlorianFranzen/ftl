# Declares the ftl.meta option. Imported both by the module mkNixos
# injects into every generated configuration and by the client module; the
# module system deduplicates path imports, so both can depend on it.
{ lib, ... }:
{
  options.ftl.meta = lib.mkOption {
    type = lib.types.attrs;
    default = { };
    description = ''
      Metadata about this configuration's place in its ftl environment
      (environment, repo, host, attr, importance, system, layers).
      Set automatically by ftl.lib.mkNixos.
    '';
  };
}
