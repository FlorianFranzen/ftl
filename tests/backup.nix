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
    machine.succeed("systemctl start mail.service srv-library.mount")
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
        assert sorted(s["tags"]) == ["fleet-entry:mail", "fleet-service:mail"], s
        assert snapshots("library") == []
        metrics = machine.succeed("cat /var/lib/metrics/fleet-backup.prom")
        assert "fleet_backup_last_success_timestamp_seconds " in metrics, metrics
        assert 'fleet_backup_snapshots{kind="state"} 2' in metrics, metrics  # mail and echo

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
        machine.succeed("rustic -P state restore --numeric-id latest:/var/lib/mail /tmp/restore")
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
        machine.succeed("rm -rf /tmp/restore && rustic -P state restore latest:/var/lib/mail /tmp/restore")
        machine.fail("test -e /tmp/restore/on-root")
        machine.succeed("test -e /tmp/restore/note")
        machine.succeed("rm /var/lib/mail/on-root && systemctl start mail.service")

    def lines(f):
        return int(machine.succeed(f"wc -l < {f}").strip())

    with subtest("a restore puts the entry back, keeps what was there, restarts the units"):
        machine.succeed("fleet-state backup mail")
        logged = lines("/var/lib/mail/log")
        machine.succeed("echo changed > /var/lib/mail/note && touch /var/lib/mail/stray && rm /var/lib/mail/inbox")
        machine.succeed("fleet-state restore mail")
        machine.succeed("grep -qx again /var/lib/mail/note && test -s /var/lib/mail/inbox")
        machine.fail("test -e /var/lib/mail/stray")
        assert machine.succeed("stat -c %u:%g /var/lib/mail/inbox").strip() == "990:990"
        # stopped for it and started again: one more line than the backup had
        machine.succeed("systemctl is-active mail.service")
        assert lines("/var/lib/mail/log") == logged + 1, (logged, lines("/var/lib/mail/log"))
        # what was there before, as a rollback snapshot
        if zfs:
            snaps = machine.succeed("zfs list -H -t snapshot -o name tank/apps/mail")
            pre = [l for l in snaps.split() if "@fleet-pre-restore-" in l]
            assert len(pre) == 1, snaps
            machine.succeed(f"mkdir -p /mnt/pre && mount -t zfs {pre[0]} /mnt/pre")
            machine.succeed("test -e /mnt/pre/stray && umount /mnt/pre")
        else:
            machine.succeed("mount -o subvolid=5 /dev/vdb /mnt/top")
            machine.succeed("test -e /mnt/top/@fleet-snapshots/mail@pre-restore-*/stray")
            machine.succeed("umount /mnt/top")

    with subtest("an older backup by id; units left stopped on request"):
        first = sorted(snapshots("mail"), key=lambda s: s["time"])[0]["id"][:8]
        machine.succeed(f"fleet-state restore mail --snapshot {first} --no-start")
        machine.fail("test -e /var/lib/mail/note")
        machine.fail("systemctl is-active mail.service")
        machine.succeed("fleet-state start mail")
        machine.succeed("systemctl is-active mail.service")
        machine.fail("fleet-state restore mail --snapshot 00000000")
        machine.fail("fleet-state restore nosuch")

    with subtest("stopping an entry stops its template units' socket, starting starts it"):
        machine.succeed("systemctl is-active echo.socket")
        machine.succeed("fleet-state stop echo")
        machine.fail("systemctl is-active echo.socket")
        machine.succeed("fleet-state start echo")
        machine.succeed("systemctl is-active echo.socket")

    with subtest("a repository gone missing fails the next backup"):
        machine.succeed("rm -r /var/backup/state")
        machine.fail("systemctl start fleet-backup.service")
        machine.fail("test -e /var/backup/state/config")
  '';
}
