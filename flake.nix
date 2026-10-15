{
  description = "flake template library - fleet outputs, update pipeline and binary cache for NixOS";

  # Only used by the test suite (checks); the library itself is pure.
  # Consumers should add: inputs.ftl.inputs.nixpkgs.follows = "nixpkgs";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # Development note: lock is intentionally pinned to the same rev as the
  # primary consumer (nixrc) so local test runs share its store.

  outputs =
    { self, nixpkgs }:
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
            self.nixosModules.compat
          ];
        };
      };

      templates.minimal = {
        path = ./templates/minimal;
        description = "Minimal ftl-based infrastructure repository";
      };

      checks.x86_64-linux = import ./tests {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        ftl = self;
        inherit nixpkgs;
      };
    };
}
