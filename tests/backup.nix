# fleet.backup on btrfs or ZFS, into local repositories: snapshots of the
# entries backed up under their real paths, labelled, tagged and recorded for
# the host; repositories only made by init; the snapshot used gone again.
{
  pkgs,
  ftl,
  backend,
}:
let
  zfs = backend == "zfs";
in
pkgs.testers.runNixOSTest {
  name = "ftl-backup-${backend}";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        ftl.nixosModules.state
        ftl.nixosModules.backup
      ];

      networking.hostName = "alpha";
      virtualisation.emptyDiskImages = [ 512 ];
      environment.systemPackages = [ pkgs.btrfs-progs ];
      boot.supportedFilesystems.zfs = zfs;
      # no root pool to import
      boot.zfs.forceImportRoot = false;
      networking.hostId = "8425e349";

      fleet.storage = if zfs then { zfsPool = "tank"; } else { btrfsDevice = "/dev/vdb"; };
      fleet.state = {
        mail = {
          path = "/var/lib/mail";
          units = [ "mail" ];
          service = "mail";
        };
        # used by a socket-activated template unit
        echo = {
          path = "/var/lib/echo";
          units = [ "echo@" ];
        };
        # with an entry mounted inside it, a timer and a service needing it
        outer = {
          path = "/var/lib/outer";
          units = [ "outer" ];
        };
        inner = {
          path = "/var/lib/outer/media";
          kind = "data";
        };
        # data, not backed up unless it opts in
        library = {
          path = "/srv/library";
          kind = "data";
        };
      };

      users.users.mail = {
        isSystemUser = true;
        group = "mail";
        uid = 990;
      };
      users.groups.mail.gid = 990;
      systemd.services.mail = {
        serviceConfig = {
          User = "mail";
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStartPre = "+${pkgs.coreutils}/bin/chown mail:mail /var/lib/mail";
        };
        script = "date >> /var/lib/mail/log";
      };

      systemd.services.outer = {
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = "date >> /var/lib/outer/log";
      };
      systemd.timers.outer = {
        wantedBy = [ "timers.target" ];
        timerConfig.OnCalendar = "yearly";
      };
      systemd.services.dep = {
        requires = [ "outer.service" ];
        after = [ "outer.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = "true";
      };

      systemd.sockets.echo = {
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "7777" ];
        socketConfig.Accept = true;
      };
      systemd.services."echo@" = {
        serviceConfig = {
          ExecStart = "${pkgs.coreutils}/bin/cat";
          StandardInput = "socket";
          DynamicUser = true;
        };
      };

      fleet.backup = {
        enable = true;
        repositories.state.repository = "/var/backup/state";
        passwordFile = "/etc/backup-password";
        metrics.textfileDir = "/var/lib/metrics";
      };
      environment.etc."backup-password".text = "test-backup-password";
    };

  testScript = ''
    import json
    zfs = ${if zfs then "True" else "False"}
    machine.wait_for_unit("multi-user.target")

    if zfs:
        machine.succeed("zpool create -O mountpoint=none tank /dev/vdb")
    else:
        machine.succeed("mkfs.btrfs -f /dev/vdb")
    machine.succeed("systemctl start mail.service srv-library.mount outer.service dep.service outer.timer var-lib-outer-media.mount")
    machine.succeed("head -c 1M /dev/urandom > /var/lib/mail/inbox && chown mail:mail /var/lib/mail/inbox")
    machine.succeed("head -c 1M /dev/urandom > /srv/library/film")

    def snapshots(label=None):
        out = machine.succeed("rustic -P state snapshots --json")
        snaps = [s for g in json.loads(out) for s in g["snapshots"]]
        return [s for s in snaps if label is None or s.get("label") == label]

    with subtest("fleet-state knows the entries"):
        listing = machine.succeed("fleet-state list")
        assert "mail" in listing and "/var/lib/mail" in listing and "backup=true" in listing, listing
        assert "library" in listing and "backup=false" in listing, listing

    with subtest("a backup does not create repositories, init does"):
        machine.fail("systemctl start fleet-backup.service")
        machine.fail("test -e /var/backup/state/config")
        machine.succeed("systemctl start fleet-backup-init.service")
        machine.succeed("fleet-state init | grep -q 'exists already'")  # idempotent
        machine.fail("test -e /var/backup/data")

    with subtest("a backup: the entry's content under its path, labelled, tagged, for the host"):
        machine.succeed("systemctl start fleet-backup.service")
        snaps = snapshots("mail")
        assert len(snaps) == 1, snaps
        s = snaps[0]
        assert s["paths"] == ["/var/lib/mail"], s
        assert s["hostname"] == "alpha", s
        tags = sorted(t for t in s["tags"] if not t.startswith("fleet-root:"))
        assert tags == ["fleet-entry:mail", "fleet-service:mail"], s["tags"]
        # the top directory's owner and mode, which rustic does not keep
        assert [t for t in s["tags"] if t.startswith("fleet-root:990:990:")], s["tags"]
        assert snapshots("library") == []
        metrics = machine.succeed("cat /var/lib/metrics/fleet-backup.prom")
        assert "fleet_backup_last_success_timestamp_seconds " in metrics, metrics
        assert 'fleet_backup_snapshots{kind="state"} 3' in metrics, metrics  # mail, echo, outer

    with subtest("the snapshot used for it is gone again"):
        if zfs:
            machine.fail("zfs list -H -t snapshot tank/apps/mail@fleet-backup")
        else:
            machine.succeed("mkdir -p /mnt/top && mount -o subvolid=5 /dev/vdb /mnt/top")
            machine.fail("test -e /mnt/top/@fleet-snapshots/mail@fleet-backup")
            machine.succeed("umount /mnt/top")
        # nor any scratch directory (fleet-state.XXXXXX; the lock stays)
        machine.fail("ls -d /run/fleet-state.??????")

    with subtest("it holds what the entry held, owners included"):
        machine.succeed("rustic -P state restore --filter-label mail --numeric-id latest:/var/lib/mail /tmp/restore")
        machine.succeed("diff -r /var/lib/mail /tmp/restore")
        assert machine.succeed("stat -c %u:%g /tmp/restore/inbox").strip() == "990:990"

    with subtest("one entry by name; an entry that is not backed up is refused"):
        machine.succeed("echo again > /var/lib/mail/note")
        machine.succeed("fleet-state backup mail")
        assert len(snapshots("mail")) == 2
        machine.fail("fleet-state backup library")
        machine.fail("fleet-state backup nosuch")
        out = machine.succeed("fleet-state snapshots mail")
        assert "/var/lib/mail" in out, out

    with subtest("the backup is taken from the entry, not from whatever is at its path"):
        machine.succeed("systemctl stop mail.service var-lib-mail.mount")
        machine.succeed("touch /var/lib/mail/on-root")
        machine.succeed("fleet-state backup mail")
        machine.succeed("rm -rf /tmp/restore && rustic -P state restore --filter-label mail latest:/var/lib/mail /tmp/restore")
        machine.fail("test -e /tmp/restore/on-root")
        machine.succeed("test -e /tmp/restore/note")
        machine.succeed("rm /var/lib/mail/on-root && systemctl start mail.service")

    def lines(f):
        return int(machine.succeed(f"wc -l < {f}").strip())

    def asides(name):
        if zfs:
            out = machine.succeed("zfs list -H -o name -r tank/apps")
            return sorted(l for l in out.split() if l.startswith(f"tank/apps/{name}.aside-"))
        machine.succeed("mount -o subvolid=5 /dev/vdb /mnt/top")
        out = machine.succeed(f"ls -d /mnt/top/@apps/{name}.aside-* 2>/dev/null || true")
        machine.succeed("umount /mnt/top")
        return sorted(l.removeprefix("/mnt/top/") for l in out.split())

    def aside_has(aside, path):
        if zfs:
            machine.succeed(f"mkdir -p /mnt/aside && mount -t zfs {aside} /mnt/aside")
            ok = machine.execute(f"test -e /mnt/aside/{path}")[0] == 0
            machine.succeed("umount /mnt/aside")
        else:
            machine.succeed("mount -o subvolid=5 /dev/vdb /mnt/top")
            ok = machine.execute(f"test -e /mnt/top/{aside}/{path}")[0] == 0
            machine.succeed("umount /mnt/top")
        return ok

    def mounted_from(path, name):
        source = machine.succeed(f"findmnt -n -o SOURCE --mountpoint {path}").strip()
        if zfs:
            assert source == f"tank/apps/{name}", source
        else:
            assert source.endswith(f"[/@apps/{name}]"), source

    with subtest("a restore swaps a restored copy in, keeps what was there aside, restarts the units"):
        machine.succeed("fleet-state backup mail")
        logged = lines("/var/lib/mail/log")
        machine.succeed("echo changed > /var/lib/mail/note && touch /var/lib/mail/stray && rm /var/lib/mail/inbox")
        machine.succeed("fleet-state restore mail")
        machine.succeed("grep -qx again /var/lib/mail/note && test -s /var/lib/mail/inbox")
        machine.fail("test -e /var/lib/mail/stray")
        assert machine.succeed("stat -c %u:%g /var/lib/mail/inbox").strip() == "990:990"
        mounted_from("/var/lib/mail", "mail")
        # stopped for it and started again: one more line than the backup had
        machine.succeed("systemctl is-active mail.service")
        assert lines("/var/lib/mail/log") == logged + 1, (logged, lines("/var/lib/mail/log"))
        kept = asides("mail")
        assert len(kept) == 1, kept
        assert aside_has(kept[0], "stray")
        assert kept[0] in machine.succeed("fleet-state list")

    with subtest("rollback swaps the copy kept aside back in, the current one goes aside"):
        machine.succeed("fleet-state rollback mail")
        machine.succeed("test -e /var/lib/mail/stray && grep -qx changed /var/lib/mail/note")
        mounted_from("/var/lib/mail", "mail")
        machine.succeed("systemctl is-active mail.service")
        kept = asides("mail")
        assert len(kept) == 1, kept  # the restored copy; the one rolled back to is in use
        machine.succeed("fleet-state rollback mail")
        machine.fail("test -e /var/lib/mail/stray")
        for aside in asides("mail"):
            machine.succeed(f"fleet-state discard {aside}")
        assert asides("mail") == []
        machine.fail("fleet-state discard tank/apps/mail")

    with subtest("two restores in the same second keep both copies aside"):
        machine.succeed("fleet-state restore mail && fleet-state restore mail")
        kept = asides("mail")
        assert len(kept) == 2, kept
        for aside in kept:
            machine.succeed(f"fleet-state discard {aside}")

    with subtest("an older backup by id; units left stopped and masked on request"):
        first = sorted(snapshots("mail"), key=lambda s: s["time"])[0]["id"][:8]
        machine.succeed(f"fleet-state restore mail --snapshot {first} --no-start")
        machine.fail("test -e /var/lib/mail/note")
        mounted_from("/var/lib/mail", "mail")
        machine.fail("systemctl is-active mail.service")
        machine.fail("systemctl start mail.service")  # masked until start
        machine.succeed("fleet-state start mail")
        machine.succeed("systemctl is-active mail.service")
        machine.fail("fleet-state restore mail --snapshot 00000000")
        machine.fail("fleet-state restore nosuch")
        for aside in asides("mail"):
            machine.succeed(f"fleet-state discard {aside}")

    with subtest("a restore leaves an entry mounted inside it alone, and what needs it running"):
        machine.succeed("echo kept > /var/lib/outer/media/big && echo one > /var/lib/outer/a")
        machine.succeed("fleet-state backup outer")
        machine.succeed("touch /var/lib/outer/stray")
        machine.succeed("fleet-state restore outer")
        machine.fail("test -e /var/lib/outer/stray")
        machine.succeed("mountpoint -q /var/lib/outer/media && grep -qx kept /var/lib/outer/media/big")
        machine.succeed("systemctl is-active outer.service dep.service outer.timer")

    with subtest("a stop twice, or two entries stopped together, start as they were"):
        machine.succeed("fleet-state stop outer && fleet-state stop outer")
        machine.succeed("fleet-state start outer")
        machine.succeed("systemctl is-active outer.service dep.service outer.timer")
        machine.succeed("fleet-state stop outer mail")
        machine.succeed("fleet-state start outer")
        machine.succeed("systemctl is-active outer.service dep.service")
        machine.fail("systemctl start mail.service")  # still stopped, still blocked
        machine.succeed("fleet-state start mail")
        machine.succeed("systemctl is-active mail.service")

    with subtest("a restore keeps the owner and mode of the entry's top directory"):
        machine.succeed("chmod 0710 /var/lib/mail")
        machine.succeed("fleet-state backup mail")
        machine.succeed("chmod 0755 /var/lib/mail && chown root:root /var/lib/mail")
        machine.succeed("fleet-state restore mail --no-start")
        assert machine.succeed("stat -c %u:%a /var/lib/mail").strip() == "990:710"
        machine.succeed("fleet-state start mail")
        for aside in asides("mail"):
            machine.succeed(f"fleet-state discard {aside}")

    with subtest("discard takes nothing but a copy kept aside"):
        stem = "tank" if zfs else "@apps"
        machine.fail(f"fleet-state discard {'tank/apps' if zfs else '@apps'}/mail.aside-20260101T000000/../../apps/echo")
        machine.fail("fleet-state discard " + ("tank/apps/mail" if zfs else "@apps/mail"))

    with subtest("an entry with something below it is not sent, and not destroyed"):
        if zfs:
            machine.succeed("zfs create -o mountpoint=legacy tank/apps/echo/child")
        else:
            machine.succeed("systemctl start var-lib-echo.mount && btrfs subvolume create /var/lib/echo/child")
        machine.fail("fleet-state send echo > /dev/null")
        if zfs:
            machine.succeed("zfs destroy tank/apps/echo/child")
        else:
            machine.succeed("btrfs subvolume delete /var/lib/echo/child")

    with subtest("stop and start: triggers, what needs the units, masks"):
        machine.succeed("fleet-state stop outer")
        machine.fail("systemctl is-active outer.timer")
        machine.fail("systemctl is-active dep.service")
        machine.fail("systemctl start outer.service")  # masked until start
        machine.succeed("fleet-state start outer")
        machine.succeed("systemctl is-active outer.service dep.service outer.timer")
        machine.succeed("systemctl is-active echo.socket")
        machine.succeed("fleet-state stop echo")
        machine.fail("systemctl is-active echo.socket")
        machine.succeed("fleet-state start echo")
        machine.succeed("systemctl is-active echo.socket")

    def no_leftovers():
        if zfs:
            out = machine.succeed("zfs list -H -t snapshot -o name -r tank")
            assert "@fleet-backup" not in out, out
        else:
            machine.succeed("mount -o subvolid=5 /dev/vdb /mnt/top")
            machine.fail("ls -d /mnt/top/@fleet-snapshots/*@fleet-backup")
            machine.succeed("umount /mnt/top")
        machine.fail("ls -d /run/fleet-state.??????")

    with subtest("a snapshot a dead run left behind is replaced, not backed up"):
        machine.succeed("echo old > /var/lib/mail/marker")
        if zfs:
            machine.succeed("zfs snapshot tank/apps/mail@fleet-backup")
            machine.succeed("mkdir -p /mnt/stale && mount -t zfs tank/apps/mail@fleet-backup /mnt/stale")
        else:
            machine.succeed("mount -o subvolid=5 /dev/vdb /mnt/top")
            machine.succeed("btrfs subvolume snapshot -r /mnt/top/@apps/mail /mnt/top/@fleet-snapshots/mail@fleet-backup")
            machine.succeed("umount /mnt/top")
        machine.succeed("echo new > /var/lib/mail/marker")
        machine.succeed("fleet-state backup mail")
        machine.succeed("rm -rf /tmp/restore && rustic -P state restore --filter-label mail latest:/var/lib/mail /tmp/restore")
        machine.succeed("grep -qx new /tmp/restore/marker")
        no_leftovers()

    with subtest("an entry that cannot be snapshotted fails, the others are backed up and pruned"):
        def latest(label):
            return max(snapshots(label), key=lambda s: s["time"])["id"]

        mail_before = latest("mail")
        mail_count = len(snapshots("mail"))
        if zfs:
            # a leftover snapshot that cannot go
            machine.succeed("zfs snapshot tank/apps/echo@fleet-backup && zfs hold keep tank/apps/echo@fleet-backup")
        else:
            # something in the way that is not a snapshot
            machine.succeed("mount -o subvolid=5 /dev/vdb /mnt/top && mkdir -p /mnt/top/@fleet-snapshots/echo@fleet-backup && umount /mnt/top")
        echo_before = latest("echo")
        last = machine.succeed("grep last_success /var/lib/metrics/fleet-backup.prom")
        machine.fail("systemctl start fleet-backup.service")
        assert latest("echo") == echo_before, "a failed snapshot made a backup"
        assert latest("mail") != mail_before, "the other entry was not backed up"
        # pruned although one entry failed (a day's backups are all but kept once)
        assert len(snapshots("mail")) < mail_count, (mail_count, len(snapshots("mail")))
        metrics = machine.succeed("cat /var/lib/metrics/fleet-backup.prom")
        assert last in metrics, (last, metrics)  # the last success stays what it was
        assert "fleet_backup_snapshots{kind=\"state\"}" in metrics, metrics
        if zfs:
            machine.succeed("zfs release keep tank/apps/echo@fleet-backup && zfs destroy tank/apps/echo@fleet-backup")
            machine.succeed("umount /mnt/stale || true")
        else:
            machine.succeed("mount -o subvolid=5 /dev/vdb /mnt/top && rmdir /mnt/top/@fleet-snapshots/echo@fleet-backup && umount /mnt/top")
        machine.succeed("systemctl start fleet-backup.service")
        no_leftovers()

    with subtest("a repository gone missing fails the next backup"):
        machine.succeed("rm -r /var/backup/state")
        machine.fail("systemctl start fleet-backup.service")
        machine.fail("test -e /var/backup/state/config")
        no_leftovers()
  '';
}
