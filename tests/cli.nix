# The fixture's .sops.yaml is what `fleetl secrets render` makes of its layout
# (SSH host keys converted with ssh-to-age), as the fleet-sops check verifies.
{
  ftl,
  fixture,
  inputs,
  ...
}:
(ftl.lib.mkFlake {
  src = fixture;
  inherit inputs;
  name = "cli";
  home = {
    bases.desktop = [
      "terminal"
      "desktop"
    ];
    username = "alice";
  };
  sops.extraRules = [
    {
      path_regex = "^tests/.*\\.yaml$";
      key_groups = [ { age = [ "age1test" ]; } ];
    }
  ];
}).checks.x86_64-linux.fleet-sops
