{
  description = "Infrastructure repository based on ftl";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ftl = {
      url = "github:FlorianFranzen/ftl";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # Layout: pkgs/ nixos/ (hosts, services, layers) home/ static/ users/, see the
  # ftl README.  `nix run .#fleetl` is the fleet's command line; a sops-nix
  # input would wire every host to its secret store.
  outputs = inputs: inputs.ftl.lib.mkFlake {
    src = ./.;
    inherit inputs;
    name = "example";
  };
}
