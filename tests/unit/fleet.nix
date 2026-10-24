# What the fleet's metadata configures besides AGENTS.md: ssh blocks for
# every host, the fleet's binary caches as substituters, the Nix defaults,
# and the repository as a git URL wherever git fetches it.
{
  lib,
  ftl,
  nixpkgs,
  fixtureArgs,
  check,
  ...
}:
let
  f = ftl.lib.mkFlake (fixtureArgs // { repo = "github:example/fleet"; });
  has = lib.hasInfix;
  cfg = host: f.nixosConfigurations.${host}.config;
  gitUrl = (ftl.lib.repo { inherit lib; }).gitUrl;
in
check "unit-fleet" (
  lib.runTests {
    # ssh <host> for every fleet host, <host>-unlock for those with an initrd key
    testSshBlocks = {
      expr = {
        alpha = has ''
          Host alpha alpha.example.org
            HostName alpha.example.org
            ForwardAgent yes
            ControlMaster auto
            ControlPath ~/.ssh/cm-%C
            ControlPersist 10m
          Host alpha-unlock
            HostName alpha.example.org
            Port 2222
            User root
            ForwardAgent no
            ControlMaster no
        '' (cfg "gamma").programs.ssh.extraConfig;
        gamma = has "Host gamma\n  HostName gamma\n" (cfg "alpha").programs.ssh.extraConfig;
        noUnlock = has "gamma-unlock" (cfg "alpha").programs.ssh.extraConfig;
      };
      expected = {
        alpha = true;
        gamma = true;
        noUnlock = false;
      };
    };

    # an address that is not a known_hosts name gets an alias
    testSshAlias = {
      expr =
        let
          g = ftl.lib.mkFlake (
            lib.recursiveUpdate fixtureArgs {
              nixos.hosts.gamma.modules = [
                { fleet.access.sshConfig.address = h: if h.name == "alpha" then "192.0.2.1" else h.name; }
              ];
            }
          );
          c = g.nixosConfigurations.gamma.config.programs.ssh.extraConfig;
        in
        {
          host = has "Host alpha alpha.example.org\n  HostName 192.0.2.1\n  HostKeyAlias alpha\n" c;
          unlock = has "  HostKeyAlias [alpha]:2222\n" c;
        };
      expected = {
        host = true;
        unlock = true;
      };
    };

    testCaches = {
      expr = {
        caches = f.fleet.caches;
        # every other host substitutes from it; the host serving it does not
        gamma = (cfg "gamma").nix.settings.extra-substituters;
        gammaKeys = (cfg "gamma").nix.settings.extra-trusted-public-keys;
        gammaStatus = (cfg "gamma").fleet.client.statusUrl;
        alpha = (cfg "alpha").fleet.client.enable;
      };
      expected = {
        caches = [
          {
            host = "alpha";
            url = "http://alpha.example.org:8080/cache";
            statusUrl = "http://alpha.example.org:8080/status/fixture.json";
            publicKeys = [ "ftl-test-1:6CA2VCkcTQDS8JL6HcoXOOHZWCqjV+3baLKM86c7dcw=" ];
          }
        ];
        gamma = [ "http://alpha.example.org:8080/cache" ];
        gammaKeys = [ "ftl-test-1:6CA2VCkcTQDS8JL6HcoXOOHZWCqjV+3baLKM86c7dcw=" ];
        gammaStatus = "http://alpha.example.org:8080/status/fixture.json";
        alpha = false;
      };
    };

    testNixDefaults = {
      expr = {
        inherit ((cfg "alpha").nix.settings) trusted-users experimental-features;
        channels = (cfg "alpha").nix.channel.enable;
      };
      expected = {
        trusted-users = [ "root" ];
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        channels = false;
      };
    };

    # a @wheel that slipped in elsewhere undoes trustWheel = false: say so
    testTrustWheelWarning = {
      expr =
        let
          g = ftl.lib.mkFlake (
            lib.recursiveUpdate fixtureArgs {
              nixos.hosts.gamma.modules = [ { nix.settings.trusted-users = [ "@wheel" ]; } ];
            }
          );
          warns = c: lib.any (lib.hasInfix "fleet.nix.trustWheel") c.config.warnings;
        in
        {
          slipped = warns g.nixosConfigurations.gamma;
          clean = warns g.nixosConfigurations.alpha;
        };
      expected = {
        slipped = true;
        clean = false;
      };
    };

    # git fetches the repository: a flake reference becomes its git URL
    testRepoUrl = {
      expr =
        let
          # the fixture's hosts set their own fleet.layers.repo
          bare =
            (ftl.lib.mkNixos {
              inherit nixpkgs;
              repo = "github:example/fleet";
              hosts.h = { };
            }).nixosConfigurations.h.config;
        in
        {
          layers = bare.fleet.layers.repo;
          client = bare.fleet.client.repo;
          meta = bare.fleet.meta.repo;
          github = gitUrl "github:o/r/main";
          gitlab = gitUrl "gitlab:o/r?ref=main";
          sourcehut = gitUrl "sourcehut:~o/r";
          gitPlus = gitUrl "git+https://git.example.org/r.git?ref=main";
          gitSsh = gitUrl "git+ssh://git@git.example.org/r.git";
          plain = gitUrl "https://git.example.org/r.git";
          scp = gitUrl "git@github.com:o/r.git";
          enterprise = gitUrl "github:o/r?host=git.example.com";
          subgroup = gitUrl "gitlab:group%2Fsub/r";
          malformed = (builtins.tryEval (gitUrl "github:o")).success;
        };
      expected = {
        layers = "https://github.com/example/fleet.git";
        client = "https://github.com/example/fleet.git";
        meta = "github:example/fleet";
        github = "https://github.com/o/r.git";
        gitlab = "https://gitlab.com/o/r.git";
        sourcehut = "https://git.sr.ht/~o/r";
        gitPlus = "https://git.example.org/r.git";
        gitSsh = "ssh://git@git.example.org/r.git";
        plain = "https://git.example.org/r.git";
        scp = "git@github.com:o/r.git";
        enterprise = "https://git.example.com/o/r.git";
        subgroup = "https://gitlab.com/group/sub/r.git";
        malformed = false;
      };
    };
  }
)
