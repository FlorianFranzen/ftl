# The pipeline proposing instead of promoting: a green bump waits on
# update/<lane>, a red one goes to broken/<lane>, the branch never moves, and
# the proposal goes away once the branch has taken it.
{
  pkgs,
  ftl,
}:
pkgs.testers.runNixOSTest {
  name = "ftl-pipeline-propose";

  nodes.builder =
    { pkgs, ... }:
    {
      imports = [ ftl.nixosModules.builder ];

      virtualisation.writableStore = true;
      virtualisation.memorySize = 3072;
      virtualisation.cores = 2;

      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];

      environment.systemPackages = [ pkgs.jq ];
      programs.git = {
        enable = true;
        config.safe.directory = "*";
      };
      environment.etc."ftl-fixture/flake.nix".source = ./fixtures/env/flake.nix;

      systemd.services.ftl-pipeline-fixture-default.serviceConfig.ReadWritePaths = [
        "/var/lib/origin.git"
      ];

      # No commit signing: a person reviews and merges the proposal.
      fleet.builder = {
        enable = true;
        propose = true;
        cache.secretKeyFile = "/var/lib/ftl/keys/cache.secret";
        repos.fixture = {
          url = "/var/lib/origin.git";
          branch = "main";
        };
      };
    };

  testScript = ''
    def rev(ref):
        return builder.succeed(f"git -C /var/lib/origin.git rev-parse refs/heads/{ref}").strip()

    def has_ref(ref):
        return builder.execute(f"git -C /var/lib/origin.git rev-parse --verify -q refs/heads/{ref}")[0] == 0

    def status(field):
        return builder.succeed(f"jq -r '.{field}' /var/lib/ftl/status/fixture.json").strip()

    def run():
        return builder.execute("systemctl start ftl-pipeline-fixture-default.service")[0]

    builder.wait_for_unit("multi-user.target")
    builder.succeed(
        "nix key generate-secret --key-name vm-test-1 > /tmp/c.sec",
        "install -o root -g root -m 0400 /tmp/c.sec /var/lib/ftl/keys/cache.secret",
    )
    builder.succeed("mkdir -p /var/lib/fixture-dep && echo v1 > /var/lib/fixture-dep/data")

    git = "git -c user.name=human -c user.email=human@test"
    builder.succeed(
        "set -e; git init -q --bare -b main /var/lib/origin.git;"
        " mkdir /tmp/seed; cd /tmp/seed; cp /etc/ftl-fixture/flake.nix .;"
        " git init -q -b main; git add flake.nix; nix flake lock; git add flake.lock;"
        f" {git} commit -q -m init; git push -q /var/lib/origin.git main;"
        " chown -R ftl:ftl /var/lib/origin.git"
    )
    seed = rev("main")

    # --- run 1: green bump -> proposed, main untouched ----------------------
    # a path input locks its mtime too: keep this one to return to in run 3
    builder.succeed("echo v2 > /var/lib/fixture-dep/data && cp -a /var/lib/fixture-dep /tmp/dep-v2")
    assert run() == 0
    assert rev("main") == seed, "main moved in propose mode"
    proposal = rev("update/default")
    assert proposal != seed
    builder.succeed(f"git -C /var/lib/origin.git merge-base --is-ancestor {seed} {proposal}")
    assert status("proposed") == "true" and status("promoted") == "false"
    alpha = status('attrs["nixos-alpha"].outPath')
    builder.succeed(f"test -f /var/lib/ftl/cache/{alpha[11:43]}.narinfo")

    # --- run 2: required host breaks -> broken/<lane>, the proposal stays ---
    builder.succeed("echo 'v3 break-beta' > /var/lib/fixture-dep/data")
    assert run() != 0
    assert rev("main") == seed
    assert has_ref("broken/default")
    assert rev("update/default") == proposal, "a red run replaced the green proposal"
    assert status("proposed") == "false"

    # --- run 3: the proposal is merged, nothing left to bump -> removed ------
    builder.succeed(
        f"git -C /var/lib/origin.git update-ref refs/heads/main {proposal} {seed}",
        "rm -rf /var/lib/fixture-dep && cp -a /tmp/dep-v2 /var/lib/fixture-dep",
    )
    assert run() == 0
    assert rev("main") == proposal
    assert not has_ref("update/default"), "merged proposal was not removed"
  '';
}
