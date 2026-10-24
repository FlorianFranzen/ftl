# Pushing a closure built on the admin's machine to a host, with nobody in
# nix.settings.trusted-users but root (fleet.nix.trustWheel is off): the
# target's daemon refuses the unsigned paths from the admin, and accepts them
# from `sudo nix-daemon`, which runs as root and authenticates the admin
# through the forwarded agent (pam_rssh), without a terminal. Once the paths
# are there, the usual deploy tools copy as the admin and find nothing to add.
{
  pkgs,
  ftl,
  nixpkgs,
  ...
}:
let
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
  system = pkgs.stdenv.hostPlatform.system;

  fleet = ftl.lib.mkNixos {
    inherit nixpkgs;
    name = "push";
    hosts = {
      laptop.keys.ssh = keys.snakeOilEd25519PublicKey;
      target.keys.ssh = keys.snakeOilEd25519PublicKey;
    };
    users.alice = {
      admin = true;
      keys.ssh = [ keys.snakeOilPublicKey ];
    };
  };

  args = host: fleet.nixosConfigurations.${host}.fleetArgs;

  node =
    host:
    { lib, ... }:
    {
      imports = (args host).modules;
      networking.hostName = lib.mkForce host;
      # the host key fleet.hosts.<host>.keys.ssh names
      services.openssh.hostKeys = [
        {
          path = "/etc/ssh/ssh_host_ed25519_key";
          type = "ed25519";
        }
      ];
      environment.etc."ssh/ssh_host_ed25519_key" = {
        source = keys.snakeOilEd25519PrivateKey;
        mode = "0600";
      };
    };

  # a derivation nobody built yet; bash is an input, so it travels along
  expr = ''derivation { name = "pushed"; system = "${system}"; builder = builtins.storePath "${pkgs.bash}/bin/bash"; args = [ "-c" "echo pushed > $out" ]; }'';
in
pkgs.testers.runNixOSTest {
  name = "ftl-push";

  # fleet.self only decides the accounts, and alice is an admin on both hosts
  node.specialArgs = (args "laptop").specialArgs;
  node.pkgsReadOnly = false;

  nodes.laptop = node "laptop";
  nodes.target = node "target";

  testScript = ''
    import shlex

    def as_alice(cmd):
        return f"su alice -l -c {shlex.quote('export SSH_AUTH_SOCK=$HOME/agent.sock; ' + cmd)}"

    start_all()
    target.wait_for_unit("sshd.service")
    laptop.wait_for_unit("multi-user.target")

    with subtest("nobody but root is trusted"):
        for m in (laptop, target):
            conf = m.succeed("grep '^trusted-users' /etc/nix/nix.conf")
            assert conf.split() == ["trusted-users", "=", "root"], conf

    # alice's key lives in her agent only
    laptop.succeed("install -d -m 700 -o alice -g users /home/alice/.ssh")
    laptop.succeed("install -m 600 -o alice -g users ${keys.snakeOilPrivateKey} /home/alice/key")
    laptop.succeed(as_alice("ssh-agent -a $SSH_AUTH_SOCK && ssh-add ~/key && rm ~/key"))
    path = laptop.succeed(as_alice("nix-build --no-out-link -E " + shlex.quote("""${expr}"""))).strip()

    with subtest("as alice, the daemon refuses the unsigned closure"):
        out = laptop.fail(as_alice(f"nix copy --no-check-sigs --to ssh-ng://target {path} 2>&1"))
        assert "signature" in out, out
        target.fail(f"test -e {path}")

    with subtest("without the forwarded agent, sudo refuses"):
        laptop.fail(as_alice(
            # a connection of its own: a multiplexed one would bring the agent along
            f"NIX_SSHOPTS='-o ForwardAgent=no -o ControlPath=none' nix copy --no-check-sigs --to 'ssh-ng://target?remote-program=sudo%20nix-daemon' {path} 2>&1"
        ))
        target.fail(f"test -e {path}")

    with subtest("through sudo nix-daemon, authenticated by the forwarded agent"):
        laptop.succeed(as_alice(f"nix copy --no-check-sigs --to 'ssh-ng://target?remote-program=sudo%20nix-daemon' {path}"))
        assert target.succeed(f"cat {path}").strip() == "pushed"
        target.succeed("journalctl _COMM=sudo | grep -q 'alice : .*COMMAND=.*nix-daemon --stdio'")

    with subtest("deploy-rs' sudoCopy: legacy ssh, sudo -u root nix-store --serve --write"):
        # the store URL deploy-rs builds for an sshUser with sudoCopy; root's
        # nix-store imports without the daemon's signature check
        other = laptop.succeed(as_alice("nix-build --no-out-link -E " + shlex.quote("""${expr}""".replace('"pushed"', '"pushed-legacy"')))).strip()
        laptop.succeed(as_alice(f"nix copy --to 'ssh://alice@target?remote-program=sudo%20-u%20root%20nix-store' {other}"))
        target.succeed(f"test -e {other}")

    with subtest("afterwards, tools that copy as alice find nothing left to add"):
        # what nixos-rebuild --target-host (nix-copy-closure) and deploy-rs (nix copy) do
        laptop.succeed(as_alice(f"nix-copy-closure --to target {path}"))
        laptop.succeed(as_alice(f"nix copy --to ssh-ng://target {path}"))
  '';
}
