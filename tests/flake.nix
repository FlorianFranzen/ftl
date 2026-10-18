{
  description = "ftl's test suite, against nixpkgs stable and unstable";

  inputs = {
    # the library under test: the repository this directory is in
    ftl.url = "../.";

    stable.url = "github:NixOS/nixpkgs/nixos-26.05";
    unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "unstable";
    };
  };

  outputs =
    {
      ftl,
      stable,
      unstable,
      sops-nix,
      ...
    }:
    let
      system = "x86_64-linux";
      lib = unstable.lib;

      # every check, named after its channel
      checksFor =
        name: nixpkgs:
        lib.mapAttrs' (check: drv: lib.nameValuePair "${name}-${check}" drv) (
          import ./default.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            inherit ftl nixpkgs sops-nix;
          }
        );
    in
    {
      checks.${system} = checksFor "stable" stable // checksFor "unstable" unstable;
    };
}
