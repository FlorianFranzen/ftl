# Host-side layers test: ftl-layers installs apps and services layers from a
# local repo, honours ftl-layers.json pins, refuses bad pins and unsigned
# targets, keeps the old generation when a build fails, rolls back, and the
# ftl.comin hook mirrors comin's generation into the system profile.
#
# The fixture layers are raw derivations (no nixpkgs evaluation inside the VM);
# their tools come from store paths that are part of the VM closure.
{
  pkgs,
  ftl,
  nixpkgs,
}:
let
  sh = "${pkgs.bash}/bin/bash";
  cu = "${pkgs.coreutils}/bin";

  fixtureFlake = pkgs.writeText "flake.nix" ''
    {
      outputs = { self }:
        let
          read = f: builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile (self + "/''${f}"));
          mk = name: script: derivation {
            inherit name;
            system = "x86_64-linux";
            builder = "${sh}";
            args = [ "-c" script ];
            PATH = "${cu}";
          };
          toolsVer = read "tools-version";
          svcVer = read "svc-version";
          svcBroken = builtins.pathExists (self + "/svc-broken");
        in {
          nixosLayers.x86_64-linux = {
            tools = mk "ftl-layer-tools" '''
              mkdir -p $out/bin $out/share/ftl-layer
              printf '#!${sh}\necho tools-''${toolsVer}\n' > $out/bin/ftl-tool
              chmod +x $out/bin/ftl-tool
              echo '{"name":"tools","kind":"apps","units":[]}' > $out/share/ftl-layer/meta.json
            ''';
            svc = mk "ftl-layer-svc" (if svcBroken then "echo broken; exit 1" else '''
              u=$out/lib/systemd/system
              mkdir -p $u/multi-user.target.wants $out/share/ftl-layer
              printf '[Unit]\nDescription=ftl demo\n[Service]\nExecStart=${sh} -c "echo svc-''${svcVer} > /run/ftl-demo; exec ${cu}/sleep infinity"\n[Install]\nWantedBy=multi-user.target\n' > $u/ftl-demo.service
              ln -s ../ftl-demo.service $u/multi-user.target.wants/ftl-demo.service
              echo '{"name":"svc","kind":"services","units":["ftl-demo.service"]}' > $out/share/ftl-layer/meta.json
            ''');
          };
        };
    }
  '';
in
pkgs.testers.runNixOSTest {
  name = "ftl-layers";

  nodes.machine =
    { config, ... }:
    {
      imports = [
        ftl.nixosModules.layers
        ftl.nixosModules.comin
      ];

      virtualisation.writableStore = true;
      virtualisation.memorySize = 2048;

      nix.settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        # Fixture builders reference tools by store path without context.
        sandbox = false;
      };

      programs.git = {
        enable = true;
        config.safe.directory = "*";
      };

      environment.etc."ftl-fixture/flake.nix".source = fixtureFlake;
      environment.etc."ftl-hook".source = config.ftl.comin.hook;

      ftl.layers = {
        installed = {
          tools.kind = "apps";
          svc.kind = "services";
        };
        repo = "/var/lib/env.git";
        timer.enable = false;
        verify = {
          mode = "ssh";
          allowedSignersFile = "/etc/ftl/allowed_signers";
        };
      };

      # comin itself is not part of this test; its hook is driven directly.
      ftl.comin.syncSystemProfile = true;
    };

  testScript = ''
    import json

    machine.wait_for_unit("multi-user.target")

    # --- signing keys + environment repo ------------------------------------
    machine.succeed(
        "mkdir -p /root/keys /etc/ftl",
        "ssh-keygen -q -t ed25519 -N \"\" -C user@test -f /root/keys/user",
        "printf 'user@test %s\\n' \"$(cut -d' ' -f1-2 /root/keys/user.pub)\" > /etc/ftl/allowed_signers",
        "git init -q --bare -b main /var/lib/env.git",
        "mkdir /root/env && cp /etc/ftl-fixture/flake.nix /root/env/",
    )

    def commit(msg, files, signed=True):
        for path, content in files.items():
            if content is None:
                machine.succeed(f"rm -f /root/env/{path}")
            else:
                machine.succeed(f"cat > /root/env/{path} <<'EOF'\n{content}\nEOF")
        sign = "-c gpg.format=ssh -c user.signingkey=/root/keys/user" if signed else ""
        sflag = "-S" if signed else ""
        machine.succeed(
            "cd /root/env && git init -q -b main 2>/dev/null; git add -A && "
            f"git -c user.name=t -c user.email=t@test {sign} commit -q {sflag} -m '{msg}' && "
            "git push -q -f /var/lib/env.git main"
        )
        return machine.succeed("git -C /root/env rev-parse HEAD").strip()

    def tool():
        return machine.succeed("bash -lc ftl-tool").strip()

    def demo():
        machine.wait_until_succeeds("systemctl is-active ftl-demo.service")
        return machine.succeed("cat /run/ftl-demo").strip()

    def generations(layer):
        return len(machine.succeed(
            f"nix-env -p /nix/var/nix/profiles/layers/{layer} --list-generations"
        ).strip().splitlines())

    # --- 1: initial install ---------------------------------------------------
    c1 = commit("v1", {"tools-version": "v1", "svc-version": "v1"})
    machine.succeed(f"ftl-layers update {c1}")
    assert tool() == "tools-v1", tool()
    assert demo() == "svc-v1", demo()

    # --- 2: update both; service restarted with new binary, no rebuild -------
    c2 = commit("v2", {"tools-version": "v2", "svc-version": "v2"})
    machine.succeed(f"ftl-layers update {c2}")
    assert tool() == "tools-v2", tool()
    machine.wait_until_succeeds("grep -qx svc-v2 /run/ftl-demo")
    assert generations("svc") == 2

    # --- 3: tools pinned to an older commit -----------------------------------
    c3 = commit("v3 pinned", {"tools-version": "v3", "ftl-layers.json": json.dumps({"tools": c1})})
    machine.succeed(f"ftl-layers update {c3}")
    assert tool() == "tools-v1", f"pin ignored: {tool()}"
    state = json.loads(machine.succeed("cat /var/lib/ftl-layers/state.json"))
    assert state["layers"]["tools"]["rev"] == c1, state

    # --- 4: pin to a non-ancestor commit is refused ---------------------------
    orphan = machine.succeed(
        "cd /root/env && t=$(git hash-object -w -t tree /dev/null) && "
        "git -c user.name=t -c user.email=t@test -c gpg.format=ssh -c user.signingkey=/root/keys/user "
        "commit-tree -S -m orphan $t"
    ).strip()
    machine.succeed(f"cd /root/env && git push -q -f /var/lib/env.git {orphan}:refs/heads/orphan")
    c4 = commit("bad pin", {"ftl-layers.json": json.dumps({"tools": orphan})})
    out = machine.fail(f"ftl-layers update {c4} 2>&1")
    assert "REFUSING" in out, out
    assert tool() == "tools-v1"

    # --- 5: broken service layer keeps the running generation -----------------
    c5 = commit("svc broken", {"ftl-layers.json": json.dumps({"tools": c1}), "svc-broken": "1"})
    machine.fail(f"ftl-layers update {c5}")
    assert demo() == "svc-v2", demo()
    assert generations("svc") == 2

    # --- 6: unsigned target is refused ----------------------------------------
    c6 = commit("unsigned", {"svc-broken": None}, signed=False)
    out = machine.fail(f"ftl-layers update {c6} 2>&1")
    assert "signature" in out, out

    # --- 7: rollback ------------------------------------------------------------
    machine.succeed("ftl-layers rollback tools")
    assert tool() == "tools-v2", f"rollback failed: {tool()}"
    machine.succeed("ftl-layers list >&2")

    # --- 8: comin hook ----------------------------------------------------------
    hook = "/etc/ftl-hook"
    # a fake toplevel whose switch-to-configuration records its invocation
    fake = machine.succeed(
        "mkdir -p /tmp/fake/bin && "
        "printf '#!${sh}\\necho \"$1\" > /tmp/stc-called\\n' > /tmp/fake/bin/switch-to-configuration && "
        "chmod +x /tmp/fake/bin/switch-to-configuration && nix-store --add /tmp/fake"
    ).strip()
    system_before = machine.succeed("readlink -f /nix/var/nix/profiles/system").strip()

    # failed deployments are ignored
    machine.succeed(f"COMIN_STATUS=failed COMIN_GIT_SHA={c2} {hook}")
    assert machine.succeed("readlink -f /nix/var/nix/profiles/system").strip() == system_before

    # a new comin generation is mirrored into the system profile + bootloader
    machine.succeed(f"mkdir -p /nix/var/nix/profiles/system-profiles && nix-env -p /nix/var/nix/profiles/system-profiles/comin --set {fake}")
    machine.succeed(f"COMIN_STATUS=done COMIN_GIT_SHA={c2} {hook}")
    assert machine.succeed("readlink -f /nix/var/nix/profiles/system").strip() == fake
    assert machine.succeed("cat /tmp/stc-called").strip() == "boot"

    # the hook also triggered a layer update to the deployed commit
    machine.wait_until_succeeds("grep -qx " + c2 + " /var/lib/ftl-layers/target")
    machine.wait_until_succeeds("systemctl show -p ActiveState --value ftl-layers-update.service | grep -qx inactive")

    # a later manual nixos-rebuild is not undone by re-running the hook
    manual = machine.succeed("readlink -f /run/current-system").strip()
    machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {manual}")
    machine.succeed("rm /tmp/stc-called")
    machine.succeed(f"COMIN_STATUS=done COMIN_GIT_SHA={c2} {hook}")
    assert machine.succeed("readlink -f /nix/var/nix/profiles/system").strip() == manual
    machine.fail("test -e /tmp/stc-called")
  '';
}
