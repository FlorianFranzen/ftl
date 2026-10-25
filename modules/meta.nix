# Declares fleet.meta: this configuration's place in its fleet, set by
# ftl.lib.mkNixos.  Imported by mkNixos's meta module and by the client
# module; the module system deduplicates path imports.
{ lib, ... }:
let
  str = lib.types.nullOr lib.types.str;
  names = lib.types.listOf lib.types.str;
  opt =
    type: description:
    lib.mkOption {
      inherit type description;
      default = if type == names then [ ] else null;
    };
in
{
  options.fleet.meta = {
    environment = opt str "The fleet's name (mkFlake's `name`).";
    repo = opt str "The fleet's repository (mkFlake's `repo`, as given).";
    repoUrl = opt str "The fleet's repository as a git URL (what git fetches: layers, status, comin).";
    host = opt str "This host's name (the directory under nixos/hosts); null outside mkNixos.";
    attr = opt str "The attribute of this configuration in nixosConfigurations.";
    importance = opt str "required, optional or ignored for the pipeline.";
    system = opt str "The host's system.";
    layers = opt names "The layers installed on this host (its own and its services').";
    services = opt names "The services this host runs.";
    users = opt names "The users with an account on this host.";
  };
}
