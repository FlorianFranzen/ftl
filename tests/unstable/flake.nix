{
  description = "ftl's test suite against nixpkgs and home-manager unstable";

  inputs = {
    # the library under test: the repository this directory is in
    ftl.url = "../..";

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # what fleet.comin hooks into, and what mkDeploy builds nodes for
    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      ftl,
      nixpkgs,
      home-manager,
      sops-nix,
      comin,
      deploy-rs,
      ...
    }:
    let
      system = "x86_64-linux";
    in
    {
      checks.${system} = import ../default.nix {
        pkgs = nixpkgs.legacyPackages.${system};
        inherit
          ftl
          nixpkgs
          home-manager
          sops-nix
          comin
          deploy-rs
          ;
      };
    };
}
