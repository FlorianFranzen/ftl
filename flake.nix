{
  description = "ftl - fleet template library: fleet outputs, update pipeline and binary cache for NixOS";

  # The library is pure and needs no inputs.  The test suite lives in two
  # flakes with their own inputs (nixpkgs, home-manager, sops-nix) and this
  # flake as a relative input: `nix flake check ./tests/stable` or
  # `./tests/unstable`.
  inputs = { };

  outputs =
    { self }:
    {
      lib = import ./lib;

      nixosModules = {
        builder = ./modules/builder.nix;
        cache = ./modules/cache.nix;
        client = ./modules/client.nix;
        layers = ./modules/layers.nix;
        comin = ./modules/comin.nix;
        state = ./modules/state.nix;
        access = ./modules/access.nix;
        secrets = ./modules/secrets.nix;
        # ftl.* -> fleet.* option aliases
        compat = ./modules/compat.nix;
        default.imports = import ./modules/all.nix;
      };

      templates.minimal = {
        path = ./templates/minimal;
        description = "Minimal ftl-based infrastructure repository";
      };
    };
}
