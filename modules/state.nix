# fleet.state: what a host keeps lives in its own subvolume or dataset, never
# on the root filesystem.
#
#   fleet.state.prometheus = {
#     path = "/var/lib/prometheus2";      # where the service keeps its state
#     units = [ "prometheus" ];           # systemd units that must not start without it
#     service = service.name;             # the fleet service it belongs to (optional)
#   };
#
# The root filesystem is disposable: everything on it comes from the
# configuration.  Whatever is worth keeping is declared here, in one of two
# kinds:
#
#   state  small and precious, the state of a service (a mail store, a database):
#          snapshotted and backed up by default.  Lives in <pool>/apps (ZFS) or
#          @apps (btrfs).
#   data   bulk files that can be obtained again (a media library): neither
#          snapshotted nor backed up by default, and kept apart so that nothing
#          operating on all state (snapshots, replication, a reservation) sweeps
#          up terabytes of it.  Lives in <pool>/data or @data.
#
# Each entry is created on demand and mounted at `path`; moving it to another
# host is moving its declaration (with its fleet service) and its contents.  On
# ZFS, the two parents get the properties of fleet.storage.zfsProperties (e.g. a
# reservation for state, a quota for data), and every dataset its own
# `zfs.properties`, applied on every boot.
#
# A broken mount cannot keep the host from booting into SSH; the entry's units
# require it instead, so they never write into the root filesystem by mistake.
#
# Their users must not depend on dynamically allocated uids (those live in
# /var/lib/nixos on the root filesystem): use a fixed uid or DynamicUser.
# An entry whose unit runs as a user without one fails evaluation.
#
# `backup` and `snapshots` are declarations for whatever does the backing up
# (fleet.backup does, with rustic); this module creates and mounts.
#
# On the host, `fleet-state` (as root) works on the entries: snapshots,
# backups and restores, and moving an entry to another host; `fleetl state`
# and `fleetl service move` drive it from the admin's machine.  It reads
# /etc/fleet-state/state.json, written here.  A host that has no entries yet
# but should receive one (a service moving to it) needs
# `fleet.storage.tool.enable`, which is on whenever there are entries or a
# ZFS pool.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  entries = config.fleet.state;
  storage = config.fleet.storage;

  device = storage.btrfsDevice;
  pool = storage.zfsPool;
  zfs = pool != null;
  zfsPackage = config.boot.zfs.package;

  # Parent (btrfs: subvolume, ZFS: dataset) of each kind.
  parents = {
    state = "apps";
    data = "data";
  };

  btrfsOptions = [
    "compress=zstd"
    "noatime"
  ];

  # The unit's user, when it is one this configuration defines (template
  # units and units from layers are not checked), unless it has a fixed uid
  # or is dynamic.
  floatingUser =
    unit:
    let
      sc = config.systemd.services.${unit}.serviceConfig or { };
      user = sc.User or null;
      dynamic = sc.DynamicUser or false;
      fixed = user != null && config.users.users ? ${user} && config.users.users.${user}.uid != null;
    in
    if dynamic == true || user == null || !(config.users.users ? ${user}) || fixed then null else user;

  floating = lib.concatLists (
    lib.mapAttrsToList (
      name: entry:
      lib.concatMap (
        unit:
        let
          u = floatingUser unit;
        in
        lib.optional (u != null) "${name}: ${unit} runs as ${u}"
      ) (lib.filter (u: !lib.hasSuffix "@" u) entry.units)
    ) entries
  );

  zfsSet =
    dataset: properties:
    lib.concatStrings (
      lib.mapAttrsToList (k: v: ''
        zfs set ${lib.escapeShellArg "${k}=${v}"} ${dataset}
      '') properties
    );

  zfsScript =
    lib.concatStrings (
      lib.mapAttrsToList (kind: dir: ''
        parent=${lib.escapeShellArg "${pool}/${dir}"}
        if ! zfs list -H -o name "$parent" >/dev/null 2>&1; then
          zfs create -o canmount=off -o mountpoint=none "$parent"
        fi
        ${zfsSet ''"$parent"'' storage.zfsProperties.${kind}}
      '') parents
    )
    + lib.concatStrings (
      lib.mapAttrsToList (_: entry: ''
        dataset=${lib.escapeShellArg entry.location}
        if ! zfs list -H -o name "$dataset" >/dev/null 2>&1; then
          zfs create -o mountpoint=legacy "$dataset"
        fi
        ${zfsSet ''"$dataset"'' (
          { "com.sun:auto-snapshot" = lib.boolToString entry.snapshots; } // entry.zfs.properties
        )}
      '') entries
    );

  hasStorage = zfs || device != null;

  # What fleet-state knows about this host's storage and entries.
  stateJson = builtins.toJSON {
    backend = if zfs then "zfs" else "btrfs";
    inherit device pool parents;
    host = config.networking.hostName;
    entries = lib.mapAttrs (_: e: {
      inherit (e)
        path
        location
        kind
        units
        service
        backup
        ;
    }) entries;
  };

  tool = pkgs.writeShellApplication {
    name = "fleet-state";
    runtimeInputs =
      with pkgs;
      [
        coreutils
        util-linux
        jq
        gnutar
        gnugrep
        systemd
        rustic
      ]
      ++ (if zfs then [ zfsPackage ] else [ btrfs-progs ])
      ++ storage.tool.packages;
    text = builtins.readFile ../scripts/fleet-state.sh;
    # `scoped` changes the cleanups in a subshell on purpose: they are its own
    excludeShellChecks = [
      "SC2030"
      "SC2031"
    ];
  };

  btrfsScript = ''
    top=$(mktemp -d /run/fleet-state.XXXXXX)
    # gone on any exit, a failing mount included
    trap 'umount "$top" 2>/dev/null || true; rmdir "$top"' EXIT
    mount -o subvolid=5 ${lib.escapeShellArg device} "$top"

    for subvolume in ${
      lib.concatStringsSep " " (
        map (d: lib.escapeShellArg "@${d}") (builtins.attrValues parents)
        ++ lib.mapAttrsToList (_: entry: lib.escapeShellArg entry.location) entries
      )
    }; do
      if [ ! -e "$top/$subvolume" ]; then
        btrfs subvolume create "$top/$subvolume"
      fi
    done
  '';
in
{
  options.fleet = {
    state = lib.mkOption {
      default = { };
      description = "What the host keeps, each in its own subvolume or dataset.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, name, ... }:
          {
            options = {
              location = lib.mkOption {
                type = lib.types.str;
                readOnly = true;
                default =
                  if zfs then "${pool}/${parents.${config.kind}}/${name}" else "@${parents.${config.kind}}/${name}";
                defaultText = lib.literalExpression ''"<pool>/apps/<name>" (ZFS) or "@apps/<name>" (btrfs), data alike'';
                description = "Its ZFS dataset or btrfs subvolume (for backups).";
              };
              path = lib.mkOption {
                type = lib.types.str;
                description = "Directory it lives in.";
              };
              kind = lib.mkOption {
                type = lib.types.enum [
                  "state"
                  "data"
                ];
                default = "state";
                description = "state: small and precious; data: bulk files that can be obtained again.";
              };
              units = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Systemd units (services) that need it mounted.";
              };
              service = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "The fleet service it belongs to, and moves with.";
              };
              backup = lib.mkOption {
                type = lib.types.bool;
                default = config.kind == "state";
                defaultText = lib.literalExpression ''kind == "state"'';
                description = "Whether it is backed up.";
              };
              snapshots = lib.mkOption {
                type = lib.types.bool;
                default = config.kind == "state";
                defaultText = lib.literalExpression ''kind == "state"'';
                description = "Whether it is snapshotted.";
              };
              zfs.properties = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                default = { };
                example = {
                  recordsize = "1M";
                };
                description = "ZFS properties of its dataset (ZFS hosts only).";
              };
            };
          }
        )
      );
    };

    storage = {
      btrfsDevice = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default =
          let
            root = config.fileSystems."/" or { };
          in
          if (root.fsType or null) == "btrfs" then root.device else null;
        defaultText = lib.literalExpression "the root filesystem's device, if it is btrfs";
        description = "btrfs filesystem that holds the @apps and @data subvolumes.";
      };

      zfsPool = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "rpool";
        description = "ZFS pool that holds <pool>/apps and <pool>/data; takes precedence over btrfs.";
      };

      tool = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = entries != { } || zfs;
          defaultText = lib.literalExpression "fleet.state != { } || fleet.storage.zfsPool != null";
          description = ''
            Install fleet-state, the host's tool for snapshots, backups,
            restores and moves of its entries.  A host that a service with
            state is to move to needs it before it has entries of its own.
          '';
        };
        package = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          default = tool;
          defaultText = lib.literalMD "fleet-state";
          description = "fleet-state, as built for this host.";
        };
        packages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          internal = true;
          description = "Further programs fleet-state needs (the backup repository's transport).";
        };
      };

      zfsProperties = lib.mapAttrs (
        kind: _:
        lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = "ZFS properties of the parent dataset of all ${kind} entries.";
        }
      ) parents;
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (storage.tool.enable && hasStorage) {
      environment.systemPackages = [ tool ];
      environment.etc."fleet-state/state.json".text = stateJson;
    })
    (lib.mkIf (entries != { }) {
      assertions = [
        {
          assertion = zfs || device != null;
          message = "fleet.state needs a btrfs filesystem (fleet.storage.btrfsDevice) or a ZFS pool (fleet.storage.zfsPool)";
        }
        {
          assertion = floating == [ ];
          message = ''
            fleet.state: a unit runs as a user without a fixed uid, so its files
            would belong to someone else after a reinstall; set users.users.<user>.uid
            or use DynamicUser:
              ${lib.concatStringsSep "\n  " floating}'';
        }
      ];

      systemd.services = lib.mkMerge (
        [
          {
            fleet-state = {
              description = "Subvolumes or datasets for state and data";
              unitConfig.DefaultDependencies = false;

              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };

              path = [
                pkgs.coreutils
                pkgs.util-linux
              ]
              ++ (if zfs then [ zfsPackage ] else [ pkgs.btrfs-progs ]);

              script = if zfs then zfsScript else btrfsScript;
            }
            // (
              if zfs then
                {
                  requires = [ "zfs-import.target" ];
                  after = [ "zfs-import.target" ];
                }
              else
                {
                  requires = [ "${utils.escapeSystemdPath device}.device" ];
                  after = [ "${utils.escapeSystemdPath device}.device" ];
                }
            );
          }
        ]
        # Every entry's units wait for (and stop without) its mount.
        ++ lib.mapAttrsToList (
          _: entry:
          lib.genAttrs entry.units (_: {
            unitConfig.RequiresMountsFor = [ entry.path ];
          })
        ) entries
      );

      # Mount units rather than fileSystems: only wanted by local-fs.target, so a
      # broken one cannot keep the host from booting (and test VMs, which replace
      # fileSystems with their own, keep them).
      systemd.mounts = lib.mapAttrsToList (
        _: entry:
        {
          where = entry.path;
          requires = [ "fleet-state.service" ];
          after = [ "fleet-state.service" ];
          wantedBy = [ "local-fs.target" ];
        }
        // (
          if zfs then
            {
              what = entry.location;
              type = "zfs";
            }
          else
            {
              what = device;
              type = "btrfs";
              options = lib.concatStringsSep "," ([ "subvol=${entry.location}" ] ++ btrfsOptions);
            }
        )
      ) entries;

      # DynamicUser state lives below /var/lib/private, which must stay 0700 even
      # when it was first created as a mount point.
      systemd.tmpfiles.rules = [ "d /var/lib/private 0700 root root -" ];
    })
  ];
}
