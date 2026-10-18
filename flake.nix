{
  description = "ftl - fleet template library: fleet outputs, update pipeline and binary cache for NixOS";

  # The library is pure and needs no inputs.  The test suite is a flake of its
  # own, tests/flake.nix, with nixpkgs stable and unstable, sops-nix and this
  # flake as inputs: `nix flake check ./tests`.
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
        default = {
          imports = [
            self.nixosModules.builder
            self.nixosModules.cache
            self.nixosModules.client
            self.nixosModules.layers
            self.nixosModules.comin
            self.nixosModules.state
            self.nixosModules.access
            self.nixosModules.secrets
            self.nixosModules.compat
          ];
        };
      };

      templates.minimal = {
        path = ./templates/minimal;
        description = "Minimal ftl-based infrastructure repository";
      };
    };
}
