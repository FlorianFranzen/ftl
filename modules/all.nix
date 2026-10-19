# Every NixOS module of ftl, in the order mkNixos imports them into a host;
# nixosModules.default imports the same list.
[
  ./builder.nix
  ./cache.nix
  ./client.nix
  ./layers.nix
  ./comin.nix
  ./state.nix
  ./backup.nix
  ./access.nix
  ./secrets.nix
]
