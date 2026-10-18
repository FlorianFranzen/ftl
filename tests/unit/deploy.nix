# mkDeploy: a deploy-rs node per host, pinned to the host key next to host.nix.
{
  lib,
  ftl,
  nixpkgs,
  fixture,
  hmStub,
  sopsStub,
  check,
  ...
}:
let
  n = ftl.lib.mkNixos {
    src = fixture + "/nixos";
    root = fixture;
    inherit nixpkgs;
    extraProfiles.extra.only = { };
    sharedModules = [
      hmStub.nixosModules.home-manager
      sopsStub.nixosModules.sops
    ];
    homes = {
      desktop-dark = { };
      terminal-dark = { };
    };
    users =
      (ftl.lib.mkUsers {
        src = fixture + "/users";
        inherit lib;
      }).users;
  };

  # stand-in for the deploy-rs flake
  deployStub = {
    inputs.nixpkgs = nixpkgs;
    lib = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: {
      activate.nixos = cfg: "activate ${system} ${cfg.config.networking.hostName}";
    });
  };

  d = ftl.lib.mkDeploy {
    inherit (n) nixosConfigurations;
    hosts = n.fleet.hosts;
    deploy = deployStub;
    sshUser = "admin";
    exclude = [ "gamma" ];
  };
in
check "unit-deploy" (
  lib.runTests {
    testNodes = {
      expr = builtins.attrNames d.nodes;
      expected = [
        "alpha"
        "beta"
      ];
    };

    # alpha has a host key: reached by fqdn, checked against it
    testPinned = {
      expr = {
        inherit (d.nodes.alpha) hostname sshUser;
        alias = builtins.elemAt d.nodes.alpha.sshOpts 1;
        strict = lib.last d.nodes.alpha.sshOpts;
        path = d.nodes.alpha.profiles.system.path;
        known = builtins.readFile d.knownHosts;
      };
      expected = {
        hostname = "alpha.example.org";
        sshUser = "admin";
        alias = "HostKeyAlias=alpha.example.org";
        strict = "StrictHostKeyChecking=yes";
        path = "activate x86_64-linux alpha";
        known = "alpha.example.org ${n.fleet.hosts.alpha.keys.ssh}\n";
      };
    };

    # beta has no ssh.pub (an age key only): plain ssh, by name
    testUnpinned = {
      expr = {
        inherit (d.nodes.beta) hostname sshOpts;
      };
      expected = {
        hostname = "beta";
        sshOpts = [ ];
      };
    };
  }
)
