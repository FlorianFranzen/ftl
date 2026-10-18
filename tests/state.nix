# fleet.state on btrfs or ZFS: state in on-demand subvolumes or datasets, and
# the safety properties that make the root filesystem disposable.
#
# The VM boots with an empty extra disk where the state should live, so first
# every mount fails: boot must still reach multi-user, and the entry's unit
# must refuse to start rather than write into the root filesystem.  Once the
# disk holds a filesystem (or pool), starting the unit creates and mounts its
# subvolume (or dataset).
{
  pkgs,
  ftl,
  backend,
}:
let
  zfs = backend == "zfs";
in
pkgs.testers.runNixOSTest {
  name = "ftl-state-${backend}";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ ftl.nixosModules.state ];

      virtualisation.emptyDiskImages = [ 512 ];
      environment.systemPackages = [ pkgs.btrfs-progs ];

      fleet.storage =
        if zfs then
          {
            zfsPool = "tank";
            zfsProperties = {
              state.refreservation = "32M";
              data.quota = "128M";
            };
          }
        else
          {
            btrfsDevice = "/dev/vdb";
          };

      boot.supportedFilesystems.zfs = zfs;
      # no root pool to import
      boot.zfs.forceImportRoot = false;
      networking.hostId = "8425e349";

      fleet.state = {
        counter = {
          path = "/var/lib/counter";
          units = [ "counter" ];
          service = "demo";
          zfs.properties.recordsize = "16K";
        };
        # DynamicUser-style state below /var/lib/private
        hidden.path = "/var/lib/private/hidden";
        # bulk data, kept apart from all state
        bulk = {
          path = "/srv/bulk";
          kind = "data";
        };
      };

      systemd.services.counter = {
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = "date >> /var/lib/counter/runs";
      };
    };

  testScript = ''
    zfs = ${if zfs then "True" else "False"}
    machine.wait_for_unit("multi-user.target")

    with subtest("a missing filesystem neither blocks boot nor lets the unit write to root"):
        machine.fail("mountpoint -q /var/lib/counter")
        machine.fail("systemctl start counter.service")
        machine.fail("test -e /var/lib/counter/runs")

    if zfs:
        machine.succeed("zpool create -O mountpoint=none tank /dev/vdb")
    else:
        machine.succeed("mkfs.btrfs -f /dev/vdb")

    with subtest("starting the unit creates and mounts its storage"):
        machine.succeed("systemctl start counter.service")
        machine.succeed("mountpoint -q /var/lib/counter")
        if zfs:
            assert machine.succeed("findmnt -no SOURCE /var/lib/counter").strip() == "tank/apps/counter"
            assert machine.succeed("zfs get -H -o value recordsize tank/apps/counter").strip() == "16K"
        else:
            assert "subvol=/@apps/counter" in machine.succeed("findmnt -no OPTIONS /var/lib/counter")
        machine.succeed("test -s /var/lib/counter/runs")

    with subtest("state and data sit next to root and apart from each other"):
        machine.succeed("systemctl start srv-bulk.mount var-lib-private-hidden.mount")
        if zfs:
            datasets = machine.succeed("zfs list -H -o name -r tank")
            for name in ["tank/apps/counter", "tank/apps/hidden", "tank/data/bulk"]:
                assert f"{name}\n" in datasets, datasets
        else:
            machine.succeed("mkdir -p /mnt/top && mount -o subvolid=5 /dev/vdb /mnt/top")
            subvolumes = machine.succeed("btrfs subvolume list /mnt/top")
            for path in ["@apps", "@apps/counter", "@apps/hidden", "@data", "@data/bulk"]:
                assert f"path {path}\n" in subvolumes, subvolumes

    if zfs:
        with subtest("state is snapshotted, data is not, and the parents are bounded"):
            def prop(p, d):
                return machine.succeed(f"zfs get -H -o value {p} {d}").strip()
            assert prop("com.sun:auto-snapshot", "tank/apps/counter") == "true"
            assert prop("com.sun:auto-snapshot", "tank/data/bulk") == "false"
            assert prop("refreservation", "tank/apps") == "32M"
            assert prop("quota", "tank/data") == "128M"
            assert prop("canmount", "tank/data") == "off"

    with subtest("creating them again is a no-op"):
        machine.succeed("systemctl restart fleet-state.service")
        machine.succeed("systemctl start var-lib-private-hidden.mount")
        machine.succeed("mountpoint -q /var/lib/private/hidden")

    with subtest("/var/lib/private stays private"):
        machine.succeed("systemd-tmpfiles --create")
        assert machine.succeed("stat -c %a /var/lib/private").strip() == "700"
  '';
}
