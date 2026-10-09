# Shared base directory of all ftl state on a host. Every other ftl path
# (state, status, cache, keys) defaults to a subdirectory of it, so one
# setting (or one mount per subdirectory) relocates everything.
{ lib, ... }:
{
  options.ftl.rootDir = lib.mkOption {
    type = lib.types.path;
    default = "/var/lib/ftl";
    description = ''
      Base directory for ftl. Defaults of the other ftl paths:
      `<rootDir>/state` (private pipeline state), `<rootDir>/status`
      (published status), `<rootDir>/cache` (binary cache) and
      `<rootDir>/keys` (signing keys).
    '';
  };
}
