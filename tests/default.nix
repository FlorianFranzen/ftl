{
  pkgs,
  ftl,
  nixpkgs,
}:
let
  lib = pkgs.lib;

  fixture = ./fixtures/layout;
  hmStub = import ./stubs/home-manager.nix { inherit lib; };
  sopsStub = import ./stubs/sops-nix.nix;

  # inputs as a consumer flake of the fixture would pass them
  inputs = {
    inherit nixpkgs;
    home-manager = hmStub;
    sops-nix = sopsStub;
    self = {
      outPath = fixture;
      shortRev = "abc1234";
    };
  };

  # Turn a lib.runTests result into a check derivation (pure eval tests).
  check =
    name: results:
    if results == [ ] then
      pkgs.runCommand name { } "echo ${name}: all tests passed > $out"
    else
      throw "${name} failed: ${builtins.toJSON results}";

  args = {
    inherit
      pkgs
      lib
      ftl
      nixpkgs
      fixture
      hmStub
      sopsStub
      inputs
      check
      ;
  };
in
{
  # 1. each mk* function called directly on its own folder
  unit-loader = import ./unit/loader.nix args;
  unit-static = import ./unit/static.nix args;
  unit-packages = import ./unit/packages.nix args;
  unit-home = import ./unit/home.nix args;
  unit-nixos = import ./unit/nixos.nix args;
  unit-users = import ./unit/users.nix args;

  # 2. each family through mkFlake, in isolation; 3. everything together
  flake-isolated = import ./flake/isolated.nix args;
  flake-full = import ./flake/full.nix args;

  # 4. the fleet-sops check of the fixture: fleetl renders its committed .sops.yaml
  cli = import ./cli.nix args;

  # 5. VM tests
  modules = import ./modules.nix args;
  layers = import ./layers.nix { inherit pkgs ftl nixpkgs; };
  pipeline = import ./pipeline.nix { inherit pkgs ftl nixpkgs; };
  pipeline-agent = import ./pipeline-agent.nix { inherit pkgs ftl nixpkgs; };
  cache = import ./cache.nix { inherit pkgs ftl nixpkgs; };
}
