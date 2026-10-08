# The pipeline with no key files: an ssh-agent (here a plain software agent; on a real
# builder a smartcard-backed one) authenticates the push over SSH and signs the lock-bump
# commit (signing.key = "key::<public key>"), and the cache is signed by a command after the
# push (cache.signer.command) instead of nix-daemon's secret-key-files.
{
  pkgs,
  ftl,
  nixpkgs,
}:
let
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
  agentSocket = "/run/test-agent/agent.sock";
  signer = pkgs.writeShellScript "test-cache-signer" ''
    # cache dir, queue file: sign the listed paths in the file:// cache
    exec ${pkgs.nix}/bin/nix --extra-experimental-features nix-command store sign \
      --store "file://$1" --key-file /var/lib/ftl/keys/signer.sec --stdin < "$2"
  '';
in
pkgs.testers.runNixOSTest {
  name = "ftl-pipeline-agent";

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

      # The environment repo lives behind sshd, as on GitHub
      services.openssh = {
        enable = true;
        hostKeys = [ { path = "/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; } ];
      };
      environment.etc."ssh/ssh_host_ed25519_key" = {
        source = keys.snakeOilEd25519PrivateKey;
        mode = "0600";
      };
      programs.ssh.knownHosts.localhost = {
        hostNames = [ "localhost" ];
        publicKey = keys.snakeOilEd25519PublicKey;
      };
      users.users.git = {
        isNormalUser = true;
        shell = "${pkgs.git}/bin/git-shell";
        openssh.authorizedKeys.keys = [ keys.snakeOilEd25519PublicKey ];
      };

      # The agent the pipeline uses, running as the pipeline user
      systemd.services.test-agent = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          User = "ftl";
          ExecStart = "${pkgs.openssh}/bin/ssh-agent -D -a ${agentSocket}";
          RuntimeDirectory = "test-agent";
        };
      };

      ftl.builder = {
        enable = true;
        promote = true;
        sshAuthSock = agentSocket;
        signing = {
          format = "ssh";
          key = "key::${keys.snakeOilEd25519PublicKey}";
        };
        verify = {
          mode = "ssh";
          allowedSignersFile = "/etc/ftl/allowed_signers";
        };
        cache.signer.command = toString signer;
        repos.fixture = {
          url = "git@localhost:/var/lib/origin.git";
          branch = "main";
        };
      };
    };

  testScript = ''
    import re

    def origin_rev(ref):
        return builder.succeed(f"git -C /var/lib/origin.git rev-parse refs/heads/{ref}").strip()

    def attr_field(attr, field):
        return builder.succeed(
            f"jq -r '.attrs[\"{attr}\"].{field}' /var/lib/ftl/status/fixture.json"
        ).strip()

    def store_hash(out_path):
        m = re.match(r"/nix/store/([a-z0-9]{32})-", out_path)
        assert m is not None, f"not a store path: {out_path!r}"
        return m.group(1)

    builder.wait_for_unit("multi-user.target")
    builder.wait_for_unit("sshd.service")
    builder.wait_for_unit("test-agent.service")

    # --- the key exists only in the agent; no deploy key, no signing key file ---
    builder.succeed(
        "install -o ftl -m 0400 ${keys.snakeOilEd25519PrivateKey} /tmp/agent-key",
        "su ftl -s /bin/sh -c 'SSH_AUTH_SOCK=${agentSocket} ssh-add /tmp/agent-key'",
        "rm /tmp/agent-key",
    )
    builder.succeed("nix key generate-secret --key-name vm-signer-1 > /tmp/s.sec")
    builder.succeed("install -o ftl -m 0400 /tmp/s.sec /var/lib/ftl/keys/signer.sec")
    builder.succeed("mkdir -p /var/lib/fixture-dep && echo v1 > /var/lib/fixture-dep/data")

    builder.succeed("mkdir -p /root/keys && ssh-keygen -q -t ed25519 -N \"\" -f /root/keys/human")
    builder.succeed(
        "mkdir -p /etc/ftl",
        "{ printf 'human@test %s\\n' \"$(cut -d' ' -f1-2 /root/keys/human.pub)\";"
        "  printf 'ftl@localhost %s\\n' '${keys.snakeOilEd25519PublicKey}'; }"
        " > /etc/ftl/allowed_signers",
    )

    human_git = "git -c user.name=human -c user.email=human@test -c gpg.format=ssh -c user.signingkey=/root/keys/human"
    builder.succeed("git init -q --bare -b main /var/lib/origin.git")
    builder.succeed(
        "set -e; mkdir /tmp/seed; cd /tmp/seed;"
        " cp /etc/ftl-fixture/flake.nix .;"
        " git init -q -b main; git add flake.nix;"
        " nix flake lock; git add flake.lock;"
        f" {human_git} commit -q -S -m init;"
        " git push -q /var/lib/origin.git main;"
        " chown -R git /var/lib/origin.git"
    )
    seed = origin_rev("main")

    # --- one run: push over ssh via the agent, agent-signed commit, signed cache ---
    builder.succeed("systemctl start ftl-pipeline-fixture-default.service")
    main1 = origin_rev("main")
    assert main1 != seed, "main did not advance"
    builder.succeed(
        "git -C /var/lib/origin.git -c gpg.ssh.allowedSignersFile=/etc/ftl/allowed_signers"
        f" verify-commit {main1}"
    )

    alpha = attr_field("nixos-alpha", "outPath")
    narinfo = f"/var/lib/ftl/cache/{store_hash(alpha)}.narinfo"
    builder.succeed(f"grep -q '^Sig: vm-signer-1:' {narinfo}")
    # every path of the pushed closure got the signer's signature
    builder.succeed(
        f"for p in $(nix-store -qR {alpha}); do"
        "   f=/var/lib/ftl/cache/$(basename $p | cut -c1-32).narinfo;"
        "   test -f $f && grep -q '^Sig: vm-signer-1:' $f;"
        " done"
    )
    # no daemon key was involved
    builder.fail(f"grep -v vm-signer-1 {narinfo} | grep -q '^Sig:'")
    builder.succeed("journalctl -u ftl-pipeline-fixture-default.service | grep -q 'signing .* path(s) with the cache sign command'")
  '';
}
