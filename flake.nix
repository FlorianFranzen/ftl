{
  description = "ftl - fleet template library: fleet outputs, update pipeline and binary cache for NixOS";

  # The library is pure and needs no inputs.  The test suite lives in two
  # flakes with their own inputs (nixpkgs, home-manager, sops-nix, comin,
  # deploy-rs) and this
  # flake as a relative input: `nix flake check ./tests/stable` or
  # `./tests/unstable`.
  inputs = { };

  outputs =
    { self }:
    {
      lib = import ./lib;

      # each module of modules/all.nix by its name, and all of them as default
      nixosModules =
        let
          all = import ./modules/all.nix;
          name = path: builtins.replaceStrings [ ".nix" ] [ "" ] (baseNameOf (toString path));
        in
        builtins.listToAttrs (
          map (path: {
            name = name path;
            value = path;
          }) all
        )
        // {
          default.imports = all;
        };

      templates.minimal = {
        path = ./templates/minimal;
        description = "Minimal ftl-based infrastructure repository";
      };
    };
}
