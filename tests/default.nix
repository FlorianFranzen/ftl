# The checks, for one set of inputs; tests/stable and tests/unstable are the
# flakes that provide them.
{
  pkgs,
  ftl,
  nixpkgs,
  home-manager,
  sops-nix,
  comin,
  deploy-rs,
}:
let
  lib = pkgs.lib;

  fixture = ./fixtures/layout;

  # inputs as a consumer flake of the fixture would pass them
  inputs = {
    inherit nixpkgs home-manager sops-nix;
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

  # mkFlake on the fixture, with what its hosts need (alpha imports
  # profiles.extra.only, alice and bob have homes)
  fixtureArgs = {
    src = fixture;
    inherit inputs;
    name = "fixture";
    nixos.extraProfiles.extra.only = { };
    home = {
      bases = {
        terminal = [ "terminal" ];
        desktop = [
          "terminal"
          "desktop"
        ];
      };
      username = "alice";
    };
  };

  args = {
    inherit
      pkgs
      lib
      ftl
      nixpkgs
      home-manager
      sops-nix
      comin
      deploy-rs
      fixture
      inputs
      fixtureArgs
      check
      ;
  };

  checks = {
    # 1. each mk* function called directly on its own folder
    unit-loader = import ./unit/loader.nix args;
    unit-static = import ./unit/static.nix args;
    unit-packages = import ./unit/packages.nix args;
    unit-home = import ./unit/home.nix args;
    unit-nixos = import ./unit/nixos.nix args;
    unit-users = import ./unit/users.nix args;
    unit-deploy = import ./unit/deploy.nix args;
    unit-smartcard = import ./unit/smartcard.nix args;
    unit-agents = import ./unit/agents.nix args;
    unit-fleet = import ./unit/fleet.nix args;

    # 2. each family through mkFlake, in isolation; 3. everything together
    flake-isolated = import ./flake/isolated.nix args;
    flake-full = import ./flake/full.nix args;
    flake-wiring = import ./flake/wiring.nix args;

    # 4. what the CLI does and checks: fleetl renders the fixture's committed
    #    .sops.yaml (fleet-sops), the generators write what they declare, the
    #    fixture's and the template's AGENTS.md are current (fleet-agents)
    cli = import ./cli.nix args;
    generators = import ./generators.nix args;
    agents = import ./agents.nix args;
    # fleetl check names the metadata file that breaks the fleet
    fleetl-check = import ./check.nix args;

    # 5. VM tests
    modules = import ./modules.nix args;
    # pcscd bound to the registered readers (QEMU's usb-ccid)
    smartcard = import ./smartcard.nix args;
    # an admin pushes an unsigned closure through sudo nix-daemon, nobody trusted
    push = import ./push.nix args;
    state-btrfs = import ./state.nix {
      inherit pkgs ftl;
      backend = "btrfs";
    };
    state-zfs = import ./state.nix {
      inherit pkgs ftl;
      backend = "zfs";
    };
    backup-btrfs = import ./backup.nix {
      inherit pkgs ftl;
      backend = "btrfs";
    };
    backup-zfs = import ./backup.nix {
      inherit pkgs ftl;
      backend = "zfs";
    };
    # fleetl service move between a btrfs and a ZFS host
    move = import ./move.nix { inherit pkgs ftl; };
    # fleet-state's swap under failure: recovery, and signals held until whole
    swap = import ./swap.nix { inherit pkgs ftl; };
    layers = import ./layers.nix { inherit pkgs ftl; };
    pipeline = import ./pipeline.nix { inherit pkgs ftl; };
    pipeline-agent = import ./pipeline-agent.nix { inherit pkgs ftl; };
    cache = import ./cache.nix { inherit pkgs ftl; };
    # fleet.secrets with sops-nix for real: decryption with the SSH host key
    services = import ./services.nix { inherit pkgs ftl sops-nix; };
  };

  # the VM tests (minutes each, KVM) are the runNixOSTest ones; everything
  # else is quick
  vmTests = builtins.attrNames (lib.filterAttrs (_: c: c ? driverInteractive) checks);
in
checks
// {
  # every check but the VM tests, for each commit (`nix build
  # ./tests/unstable#checks.x86_64-linux.fast`); the VM tests as `nix flake check`
  fast = pkgs.linkFarm "fast" (
    lib.mapAttrsToList (name: path: { inherit name path; }) (builtins.removeAttrs checks vmTests)
  );
}
