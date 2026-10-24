{
  description = "Infrastructure repository based on ftl";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # ftl has no inputs of its own: it uses this flake's nixpkgs
    ftl.url = "github:FlorianFranzen/ftl";
  };

  # Layout: pkgs/ nixos/ (hosts, services, layers) home/ static/ users/, see the
  # ftl README.  `nix run .#fleetl` is the fleet's command line; a sops-nix
  # input would wire every host to its secret store.  AGENTS.md is generated
  # from the layout: `nix run .#fleetl -- agents sync` after changing it.
  outputs = inputs: inputs.ftl.lib.mkFlake {
    src = ./.;
    inherit inputs;
    name = "example";
  };
}
