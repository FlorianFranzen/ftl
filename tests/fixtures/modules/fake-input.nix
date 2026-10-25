# Stands in for an input's NixOS module that is a path (disko's, sops-nix's):
# its option may be declared only once, however often it is imported.
{ lib, ... }:
{
  options.fake.declared = lib.mkOption { default = true; };
}
