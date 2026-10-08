{
  description = "Infrastructure repository based on ftl";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ftl = {
      url = "github:FlorianFranzen/ftl";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # Layout: pkgs/ nixos/ home/ static/ (see the ftl README)
  outputs = inputs: inputs.ftl.lib.mkFlake {
    src = ./.;
    inherit inputs;
    name = "example";
  };
}
