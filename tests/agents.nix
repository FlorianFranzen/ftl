# The fleet-agents check: the fixture's and the template's committed AGENTS.md
# are what `fleetl agents sync` writes for them, and a stale one fails.
{
  pkgs,
  ftl,
  inputs,
  fixtureArgs,
  ...
}:
let
  template = ../templates/minimal;
  example = ftl.lib.mkFlake {
    src = template;
    inputs = {
      inherit (inputs) nixpkgs;
      self.outPath = template;
    };
    name = "example";
  };

  check = f: f.checks.x86_64-linux.fleet-agents;
in
pkgs.runCommand "fleet-agents"
  {
    fixture = check (ftl.lib.mkFlake fixtureArgs);
    template = check example;
    stale = pkgs.testers.testBuildFailure (
      check (ftl.lib.mkFlake (fixtureArgs // { agents.extra = [ "## More" ]; }))
    );
  }
  ''
    grep -q "AGENTS.md is stale; run fleetl agents sync" "$stale/testBuildFailure.log"
    grep -q "^+## More" "$stale/testBuildFailure.log"
    touch "$out"
  ''
