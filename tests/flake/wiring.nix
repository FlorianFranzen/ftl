# What mkFlake wires up for a consumer: the modules of known inputs when they
# are paths (imported once, also when the fleet lists them itself), `inputs`
# for every module, registry names of one's own, the `deploy` output with
# deploy-rs' checks, a dev shell.
{
  lib,
  ftl,
  inputs,
  fixtureArgs,
  deploy-rs,
  check,
  ...
}:
let
  # disko's and sops-nix's modules are paths; lanzaboote's is a function,
  # which mkFlake leaves to the fleet (imported twice it would be declared twice)
  pathModule = ../fixtures/modules/fake-input.nix;
  functionModule =
    { lib, ... }:
    {
      options.fake.function = lib.mkOption { default = true; };
    };
  withInputs =
    extra: args:
    ftl.lib.mkFlake (lib.recursiveUpdate fixtureArgs ({ inputs = inputs // extra; } // args));

  auto = withInputs {
    disko.nixosModules.disko = pathModule;
    lanzaboote.nixosModules.lanzaboote = functionModule;
  } { };
  listed = withInputs { disko.nixosModules.disko = pathModule; } {
    nixos.sharedModules = [ pathModule ];
  };
  deployed = withInputs { inherit deploy-rs; } {
    deploy = {
      sshUser = "admin";
      exclude = [ "beta" ];
    };
    nixos.exportInputs = {
      fleet = "self";
      nixpkgs = "nixpkgs";
    };
    nixos.hosts.gamma.modules = [
      (
        { inputs, ... }:
        {
          environment.etc.rev.text = inputs.self.shortRev;
        }
      )
    ];
  };
  gamma = f: f.nixosConfigurations.gamma.config;
  off = withInputs { disko.nixosModules.disko = pathModule; } { nixos.inputModules = false; };
  ready = withInputs { inherit deploy-rs; } { deploy.nodes.x = { }; };
  noDeployRs = withInputs { } { deploy.sshUser = "admin"; };
  # beta is aarch64: deploy-rs' checks of each system get only its hosts
  mixed = withInputs { inherit deploy-rs; } { deploy.sshUser = "admin"; };
  activateInputs =
    system:
    builtins.length (
      lib.filter (lib.hasInfix "activatable") (
        builtins.attrNames mixed.checks.${system}.deploy-activate.inputDerivation or { }
      )
    );
in
check "flake-wiring" (
  lib.runTests {
    testInputModules = {
      expr = {
        disko = (gamma auto).fake.declared;
        # a function module is not imported for the fleet
        lanzaboote = auto.nixosConfigurations.gamma.options.fake ? function;
        # listed by the fleet too: imported once, no duplicate declaration
        listed = (gamma listed).fake.declared;
      };
      expected = {
        disko = true;
        lanzaboote = false;
        listed = true;
      };
    };

    testDeploy = {
      expr = {
        nodes = builtins.attrNames deployed.deploy.nodes;
        sshUser = deployed.deploy.nodes.gamma.sshUser;
        checks = lib.filter (lib.hasPrefix "deploy-") (builtins.attrNames deployed.checks.x86_64-linux);
      };
      expected = {
        nodes = [
          "alpha"
          "gamma"
        ];
        sshUser = "admin";
        checks = [
          "deploy-activate"
          "deploy-schema"
        ];
      };
    };

    testRegistryAndInputs = {
      expr = {
        registry = builtins.attrNames (gamma deployed).nix.registry;
        rev = (gamma deployed).environment.etc.rev.text;
      };
      expected = {
        registry = [
          "fleet"
          "nixpkgs"
        ];
        rev = "abc1234";
      };
    };

    testDevShell = {
      expr = {
        packages = map lib.getName deployed.devShells.x86_64-linux.default.nativeBuildInputs;
        # a dev shell of the fleet's own replaces it
        own = (withInputs { } { devShells.x86_64-linux.default = "mine"; }).devShells.x86_64-linux.default;
      };
      expected = {
        packages = [
          "fleetl"
          "sops"
          "ssh-to-age"
          "age"
          "deploy-rs"
        ];
        own = "mine";
      };
    };

    testInputModulesOff = {
      expr = off.nixosConfigurations.gamma.options ? fake;
      expected = false;
    };

    testDeployVariants = {
      expr = {
        # a ready output passes through, without checks of ftl's
        ready = ready.deploy.nodes;
        readyChecks = ready.checks.x86_64-linux ? deploy-activate;
        noDeployRs = (builtins.tryEval (builtins.attrNames noDeployRs.checks)).success;
        # per system, only its hosts
        mixed = {
          x86 = builtins.attrNames (
            lib.filterAttrs (n: _: lib.hasPrefix "deploy-" n) mixed.checks.x86_64-linux
          );
          aarch64 = builtins.attrNames (
            lib.filterAttrs (n: _: lib.hasPrefix "deploy-" n) mixed.checks.aarch64-linux
          );
        };
      };
      expected = {
        ready.x = { };
        readyChecks = false;
        noDeployRs = false;
        mixed = {
          x86 = [
            "deploy-activate"
            "deploy-schema"
          ];
          aarch64 = [
            "deploy-activate"
            "deploy-schema"
          ];
        };
      };
    };
  }
)
