# End-to-end pipeline test: lock bump, build, fast-forward of main, layer
# pinning, broken and retention semantics - against a local bare repo, offline.
{
  pkgs,
  ftl,
  nixpkgs,
}:
pkgs.testers.runNixOSTest {
  name = "ftl-pipeline";

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

      # The test script inspects the ftl-owned bare repo as root.
      programs.git = {
        enable = true;
        config.safe.directory = "*";
      };
      environment.etc."ftl-fixture/flake.nix".source = ./fixtures/env/flake.nix;

      ftl.builder = {
        enable = true;
        promote = true;
        signing = {
          format = "ssh";
          key = "/var/lib/ftl/keys/sign";
        };
        # cache, status and keys use the ftl.rootDir defaults
        repos.fixture = {
          url = "/var/lib/origin.git";
          branch = "main";
          keepGenerations = 1;
        };
      };
    };

  testScript = ''
    import json
    import re

    def origin_rev(ref):
        return builder.succeed(f"git -C /var/lib/origin.git rev-parse refs/heads/{ref}").strip()

    def attr_field(attr, field):
        return builder.succeed(
            f"jq -r '.attrs[\"{attr}\"].{field}' /var/lib/ftl/status/fixture.json"
        ).strip()

    def narinfo_exists(out_path):
        m = re.match(r"/nix/store/([a-z0-9]{32})-", out_path)
        assert m is not None, f"not a store path: {out_path!r}"
        return builder.execute(f"test -f /var/lib/ftl/cache/{m.group(1)}.narinfo")[0] == 0

    builder.wait_for_unit("multi-user.target")

    # --- keys and fixture material ------------------------------------------
    builder.succeed("ssh-keygen -q -t ed25519 -N \"\" -f /var/lib/ftl/keys/sign && chown ftl /var/lib/ftl/keys/sign")
    builder.succeed(
        "nix key generate-secret --key-name vm-test-1 > /tmp/c.sec",
        "install -o root -g ftl -m 0440 /tmp/c.sec /var/lib/ftl/keys/cache.secret",
    )
    builder.succeed("mkdir -p /var/lib/fixture-dep && echo v1 > /var/lib/fixture-dep/data")

    # --- seed the environment repo ------------------------------------------
    builder.succeed(
        "git init -q --bare -b main /var/lib/origin.git"
    )
    builder.succeed(
        "set -e; mkdir /tmp/seed; cd /tmp/seed;"
        " cp /etc/ftl-fixture/flake.nix .;"
        " git init -q -b main; git add flake.nix;"
        " nix flake lock; git add flake.lock;"
        " git -c user.name=seed -c user.email=seed@test commit -q -m init;"
        " git push -q /var/lib/origin.git main;"
        " chown -R ftl:ftl /var/lib/origin.git"
    )

    def pins_at(ref):
        return json.loads(builder.succeed(
            f"git -C /var/lib/origin.git show {ref}:ftl-layers.json"
        ))

    def is_signed(ref):
        return "gpgsig" in builder.succeed(f"git -C /var/lib/origin.git cat-file commit {ref}")

    seed = origin_rev("main")

    # --- run 1: everything green -> pins written, main fast-forwarded --------
    builder.succeed("systemctl start ftl-pipeline-fixture-default.service")
    main1 = origin_rev("main")
    assert main1 != seed, "main did not advance"
    builder.succeed(f"git -C /var/lib/origin.git merge-base --is-ancestor {seed} {main1}")
    assert pins_at("main") == {"gaming": "latest"}, pins_at("main")
    assert is_signed("main"), "builder commit is not signed"
    assert attr_field("nixos-layer-gaming", "status") == "ok"
    alpha_out1 = attr_field("nixos-alpha", "outPath")
    gaming_out1 = attr_field("nixos-layer-gaming", "outPath")
    assert narinfo_exists(alpha_out1), "alpha closure missing from cache"
    assert narinfo_exists(gaming_out1), "gaming layer missing from cache"

    # --- run 2: layer breaks -> main still advances, layer pinned -------------
    builder.succeed("echo 'v2 break-gaming' > /var/lib/fixture-dep/data")
    builder.succeed("systemctl start ftl-pipeline-fixture-default.service")
    main2 = origin_rev("main")
    assert main2 != main1, "main did not advance although only a layer failed"
    builder.succeed(f"git -C /var/lib/origin.git merge-base --is-ancestor {main1} {main2}")
    assert attr_field("nixos-layer-gaming", "status") == "build-failed"
    assert pins_at("main") == {"gaming": main1}, pins_at("main")
    assert builder.succeed("jq -r .promoted /var/lib/ftl/status/fixture.json").strip() == "true"

    # retention (keepGenerations = 1): alpha's old generation is pruned, the
    # pinned gaming layer survives.
    alpha_out2 = attr_field("nixos-alpha", "outPath")
    assert narinfo_exists(alpha_out2), "new alpha closure missing from cache"
    assert not narinfo_exists(alpha_out1), "old alpha generation not pruned"
    assert narinfo_exists(gaming_out1), "pinned gaming layer was pruned"

    # --- run 3: required host breaks -> main untouched, broken ref pushed -----
    builder.succeed("echo 'v3 break-beta break-gaming' > /var/lib/fixture-dep/data")
    builder.fail("systemctl start ftl-pipeline-fixture-default.service")
    assert origin_rev("main") == main2, "main moved although a required host failed"
    builder.succeed(
        "git -C /var/lib/origin.git for-each-ref refs/heads/broken | grep -q broken"
    )
    assert attr_field("nixos-beta", "status") == "build-failed"
    assert builder.succeed("jq -r .promoted /var/lib/ftl/status/fixture.json").strip() == "false"

    # --- run 4: unchanged candidate -> early exit -----------------------------
    builder.succeed("systemctl start ftl-pipeline-fixture-default.service")
    assert origin_rev("main") == main2

    # --- run 5: human commit on main + fixed layer -> builds on top, unpins ---
    builder.succeed(
        "set -e; cd /tmp/seed; git pull -q --ff-only /var/lib/origin.git main;"
        " echo docs > README; git add README;"
        " git -c user.name=human -c user.email=human@test commit -q -m docs;"
        " git push -q /var/lib/origin.git main;"
        " chown -R ftl:ftl /var/lib/origin.git"
    )
    human = origin_rev("main")
    builder.succeed("echo 'v5 fixed' > /var/lib/fixture-dep/data")
    builder.succeed("systemctl start ftl-pipeline-fixture-default.service")
    main5 = origin_rev("main")
    assert main5 != human
    builder.succeed(f"git -C /var/lib/origin.git merge-base --is-ancestor {human} {main5}")
    assert pins_at("main") == {"gaming": "latest"}, pins_at("main")

    # no force pushes ever happened on main
    builder.succeed(
        f"git -C /var/lib/origin.git merge-base --is-ancestor {seed} {main5}"
    )
  '';
}
