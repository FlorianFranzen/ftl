# fleet-state's swap under failure (btrfs): docs/review.md listed these as
# not covered by a test.
#
#   - swap_recover: a rollback whose second rename fails (the copy to swap
#     in is immutable) puts the entry back as it was, running, and leaves
#     the copy aside untouched;
#   - a TERM, then a HUP (the admin's connection gone), arriving while a
#     swap waits for a slow unit to stop: the swap still finishes, the entry
#     is whole and running, and only then does the run end, with 143 or 129.
{
  pkgs,
  ftl,
  ...
}:
pkgs.testers.runNixOSTest {
  name = "ftl-swap";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        ftl.nixosModules.state
        ftl.nixosModules.backup
      ];

      networking.hostName = "alpha";
      virtualisation.emptyDiskImages = [ 512 ];
      environment.systemPackages = [
        pkgs.btrfs-progs
        pkgs.e2fsprogs # chattr
      ];

      fleet.storage.btrfsDevice = "/dev/vdb";
      fleet.state.app = {
        path = "/var/lib/app";
        units = [ "app" ];
      };

      # stopping takes a while: a swap sits in its critical section meanwhile
      systemd.services.app = {
        serviceConfig = {
          DynamicUser = true;
          ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
          ExecStop = "${pkgs.coreutils}/bin/sleep 6";
        };
      };

      fleet.backup = {
        enable = true;
        repositories.state.repository = "/var/backup/state";
        passwordFile = "/etc/backup-password";
      };
      environment.etc."backup-password".text = "test-backup-password";
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkfs.btrfs -f /dev/vdb")
    machine.succeed("systemctl restart fleet-state.service")
    machine.succeed("systemctl start app.service")
    machine.succeed("echo one > /var/lib/app/v")
    machine.succeed("systemctl start fleet-backup-init.service")
    machine.succeed("fleet-state backup app")
    machine.succeed("echo two > /var/lib/app/v")
    # now: the entry holds "two", the restore below puts "one" in and keeps
    # "two" aside
    machine.succeed("fleet-state restore app")
    assert machine.succeed("cat /var/lib/app/v").strip() == "one"

    machine.succeed("mkdir -p /mnt/top")

    def top(cmd):
        machine.succeed("mount -o subvolid=5 /dev/vdb /mnt/top")
        try:
            return machine.succeed(cmd)
        finally:
            machine.succeed("umount /mnt/top")

    def asides():
        return sorted(top("ls -d /mnt/top/@apps/app.aside-* 2>/dev/null || true").split())

    def content(location):
        return top(f"cat /mnt/top/{location}/v").strip()

    def whole(expected):
        assert machine.succeed("cat /var/lib/app/v").strip() == expected
        source = machine.succeed("findmnt -n -o SOURCE --mountpoint /var/lib/app").strip()
        assert source.endswith("[/@apps/app]"), source
        machine.succeed("systemctl is-active app.service")

    kept = asides()
    assert len(kept) == 1, kept
    assert content(kept[0].removeprefix("/mnt/top/")) == "two"

    with subtest("swap_recover: the second rename fails, the entry is put back"):
        top(f"chattr +i {kept[0]}")
        rc, out = machine.execute("fleet-state rollback app 2>&1")
        assert rc == 1, (rc, out)
        assert "app: the swap failed; putting @apps/app.aside-" in out and " back" in out, out
        top(f"chattr -i {kept[0]}")
        whole("one")
        # nothing still blocked
        machine.fail("ls /run/systemd/system/*.d/fleet-state-app.conf")
        # no copy of the current one left aside by the failed swap
        assert asides() == kept, asides()
        assert content(kept[0].removeprefix("/mnt/top/")) == "two"

    def interrupted(signal):
        """A rollback as a unit of its own (fleet-state its main process, so
        the signal reaches it alone), the signal sent while its units stop,
        the exit status as systemd saw it.

        Not `pkill -f` on a backgrounded `sh -c`: that matches the wrapper too,
        whose end makes systemd signal the whole unit, `systemctl stop`
        included; the step then fails and the entry is put back (exit 1), a
        different case."""
        unit = f"rollback-{signal.lower()}"
        machine.succeed(
            f"systemd-run --unit={unit} -p RemainAfterExit=yes -p StandardOutput=file:/tmp/{unit}.log"
            f" -p StandardError=file:/tmp/{unit}.log /run/current-system/sw/bin/fleet-state rollback app"
        )
        machine.wait_until_succeeds("systemctl show -P ActiveState app.service | grep -q deactivating", timeout=30)
        machine.succeed(f"systemctl kill --kill-whom=main --signal={signal} {unit}")
        machine.wait_until_succeeds(f"systemctl show -P SubState {unit} | grep -qx -e exited -e failed", timeout=60)
        rc = machine.succeed(f"systemctl show -P ExecMainStatus {unit}").strip()
        out = machine.succeed(f"cat /tmp/{unit}.log")
        return rc, out

    with subtest("TERM in the middle of a swap: it finishes, then the run ends"):
        rc, out = interrupted("TERM")
        assert rc == "143", (rc, out)
        assert "swapped in" in out, out
        # the copy kept aside is in, the one that was there went aside
        whole("two")
        now = asides()
        assert len(now) == 1 and content(now[0].removeprefix("/mnt/top/")) == "one", now

    with subtest("HUP (the admin's connection gone) in the middle of a swap: the same"):
        rc, out = interrupted("HUP")
        assert rc == "129", (rc, out)
        assert "swapped in" in out, out
        whole("one")
        now = asides()
        assert len(now) == 1 and content(now[0].removeprefix("/mnt/top/")) == "two", now

    with subtest("nothing temporary is left"):
        machine.fail("ls -d /run/fleet-state.??????")
  '';
}
