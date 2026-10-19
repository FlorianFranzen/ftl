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
        assert 'fleet_backup_snapshots{kind="state"} 1' in metrics, metrics

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

    with subtest("a repository gone missing fails the next backup"):
        machine.succeed("rm -r /var/backup/state")
        machine.fail("systemctl start fleet-backup.service")
        machine.fail("test -e /var/backup/state/config")
  '';
}
