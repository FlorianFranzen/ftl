# AGENTS.md: the repository's (fleet.agents), and each host's /etc/AGENTS.md.
{
  lib,
  ftl,
  fixture,
  fixtureArgs,
  check,
  ...
}:
let
  f = ftl.lib.mkFlake (
    fixtureArgs
    // {
      repo = "github:example/fleet";
      agents.extra = [ "## Notes\n\nThe fixture's own words." ];
    }
  );
  text = f.fleet.agents;
  has = lib.hasInfix;
  cfg = host: f.nixosConfigurations.${host}.config;
  hostText = host: (cfg host).environment.etc."AGENTS.md".text;
in
check "unit-agents" (
  lib.runTests {
    testFleetText = {
      expr = {
        title = lib.hasPrefix "# AGENTS.md: the fixture fleet\n" text;
        repo = has "**fixture** (`github:example/fleet`)" text;
        hostRow = has "| `beta` | aarch64-linux | optional | `mesh` | `tools` | `alice` | headless |" text;
        noKeyRow = has "| `gamma` | x86_64-linux | required | `mesh` | `tools` | `alice` | none registered |" text;
        reader = has "- `beta` (headless): `builder` (USB 1050:0407, port 1-4)" text;
        headless = has "Nobody is present: nothing may wait for a touch" text;
        # no attended host in the fixture
        attended = has "Someone is present and can touch the key" text;
        pin = has "Never guess a PIN" text;
        cache = has "- http://alpha.example.org:8080/cache, served by `alpha`" text;
        service = has "| `mesh` | hub: `alpha`; spoke: `beta`, `gamma` | `tools` |" text;
        user = has "| `alice` | yes | all | - |" text;
        push = has "nix copy --no-check-sigs --to 'ssh-ng://<host>?remote-program=sudo%20nix-daemon' <path>" text;
        extra = lib.hasSuffix "## Notes\n\nThe fixture's own words.\n" text;
      };
      expected = {
        title = true;
        repo = true;
        hostRow = true;
        noKeyRow = true;
        reader = true;
        headless = true;
        attended = false;
        pin = true;
        cache = true;
        service = true;
        user = true;
        push = true;
        extra = true;
      };
    };

    # credentials in the repository's URL stay out of the file
    testRepoCredentials = {
      expr =
        let
          t = (ftl.lib.mkFlake (fixtureArgs // { repo = "https://ci:s3cret@git.example.org/fleet"; })).fleet.agents;
        in
        {
          token = has "s3cret" t;
          url = has "(`https://git.example.org/fleet`)" t;
        };
      expected = {
        token = false;
        url = true;
      };
    };

    # each host carries its own part, and what its configuration adds
    testHostText = {
      expr = {
        title = lib.hasPrefix "# AGENTS.md: alpha, a host of the fixture fleet\n" (hostText "alpha");
        facts = has "- services: `mesh` (hub), `web`" (hostText "alpha");
        data = has "`fqdn` = `alpha.example.org`" (hostText "alpha");
        serves = has "serves the binary cache `http://alpha.example.org:8080/cache`" (hostText "alpha");
        noReader = has "No smartcard reader is registered for this host" (hostText "alpha");
        access = has "## Access" (hostText "alpha");
        unlock = has "`ssh <host>-unlock`" (hostText "alpha");
        layers = has "## Layers" (hostText "alpha");
        gammaCache = has "This host substitutes from `http://alpha.example.org:8080/cache`" (
          hostText "gamma"
        );
        betaHeadless = has "This host is **headless**" (hostText "beta");
        betaHead = has "- hardware key: **headless**, 1 reader(s) registered" (hostText "beta");
        # listed once, by fleet.smartcard's section
        betaReaderOnce =
          builtins.length (lib.splitString "`builder` (USB 1050:0407" (hostText "beta")) == 2;
        push = has "`nix copy --no-check-sigs --to 'ssh-ng://alpha?remote-program=sudo%20nix-daemon' <path>`" (
          hostText "alpha"
        );
      };
      expected = {
        title = true;
        facts = true;
        data = true;
        serves = true;
        noReader = true;
        access = true;
        unlock = true;
        layers = true;
        gammaCache = true;
        betaHeadless = true;
        betaHead = true;
        betaReaderOnce = true;
        push = true;
      };
    };

    # the checks of generated files exist once the repository has the file
    testChecksNeedTheFile = {
      expr =
        let
          withoutAgents = builtins.path {
            name = "fixture-without-agents";
            path = fixture;
            filter = path: _: baseNameOf path != "AGENTS.md";
          };
          g = ftl.lib.mkFlake (fixtureArgs // { src = withoutAgents; });
        in
        {
          with' = f.checks.x86_64-linux ? fleet-agents;
          without = g.checks.x86_64-linux ? fleet-agents;
        };
      expected = {
        with' = true;
        without = false;
      };
    };
  }
)
