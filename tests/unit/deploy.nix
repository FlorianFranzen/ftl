# mkDeploy: a deploy-rs node per host, pinned to the host key next to host.nix.
{
  lib,
  ftl,
  nixpkgs,
  fixture,
  home-manager,
  sops-nix,
  deploy-rs,
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
      home-manager.nixosModules.home-manager
      sops-nix.nixosModules.sops
    ];
    # stand-ins for home configurations (home-manager wants a stateVersion)
    homes = {
      desktop-dark.home.stateVersion = "26.05";
      terminal-dark.home.stateVersion = "26.05";
    };
    users =
      (ftl.lib.mkUsers {
        src = fixture + "/users";
        inherit lib;
      }).users;
  };

  d = ftl.lib.mkDeploy {
    inherit (n) nixosConfigurations;
    hosts = n.fleet.hosts;
    deploy = deploy-rs;
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
        activatable = lib.isDerivation d.nodes.alpha.profiles.system.path;
        known = builtins.readFile d.knownHosts;
      };
      expected = {
        hostname = "alpha.example.org";
        sshUser = "admin";
        alias = "HostKeyAlias=alpha.example.org";
        strict = "StrictHostKeyChecking=yes";
        activatable = true;
        known = "alpha.example.org ${n.fleet.hosts.alpha.keys.ssh}\n";
      };
    };

    # an sshUser other than root copies through sudo, root does not need to
    testSudoCopy = {
      expr = {
        admin = d.sudoCopy or false;
        root =
          (ftl.lib.mkDeploy {
            inherit (n) nixosConfigurations;
            hosts = n.fleet.hosts;
            deploy = deploy-rs;
          }) ? sudoCopy;
      };
      expected = {
        admin = true;
        root = false;
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
