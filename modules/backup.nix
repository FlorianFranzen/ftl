# fleet.backup: every fleet.state entry with `backup = true`, backed up with
# rustic into one repository per kind (state, data).
#
#   fleet.backup = {
#     enable = true;
#     repositories.state = { repository = "opendal:sftp"; options = { ... }; };
#     passwordFile = config.sops.secrets."backup/password".path;
#     credentialFiles.ssh-key = config.sops.secrets."backup/ssh-key".path;
#   };
#
# Each run snapshots every entry (a ZFS snapshot or read-only btrfs snapshot
# of its dataset or subvolume), backs the snapshot up under the entry's real
# path, with the entry's name as label, the host's name as host and the
# entry's service as tag, and drops it again: consistent copies of live data
# without stopping anything.  Then each repository is pruned by `retention`.
#
# Repositories are created once per host, by hand, never by a backup (a
# repository gone missing must fail the backup rather than be replaced):
#
#   sudo fleet-state init
#
# The rustic profiles are /etc/rustic/<kind>.toml, so the repositories can be
# used directly too (`sudo rustic -P state snapshots`); `fleet-state
# snapshots` and `fleet-state restore` (see the state module) are the
# entry-level view.  `credentialFiles` are what the repository options read
# besides the password (an SSH key, a token file): a restore on another host,
# when a service moves (`fleetl service move --via backup`), gets them for
# the time of the restore.
#
# A backup covers the entry's own dataset or subvolume: a nested subvolume or
# child dataset below it is not part of the snapshot, and so not backed up.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.fleet.backup;
  fleetState = lib.getExe config.fleet.storage.tool.package;

  toml = pkgs.formats.toml { };

  entries = lib.filterAttrs (_: e: e.backup) config.fleet.state;
  kinds = lib.filter (kind: lib.any (e: e.kind == kind) (builtins.attrValues entries)) [
    "state"
    "data"
  ];

  profiles = lib.genAttrs kinds (kind: {
    repository = cfg.repositories.${kind} // {
      password-file = cfg.passwordFile;
    };
    forget = lib.mapAttrs' (k: v: lib.nameValuePair "keep-${k}" v) (
      lib.filterAttrs (_: v: v != null) cfg.retention.${kind}
    );
  });
in
{
  options.fleet.backup = {
    enable = lib.mkEnableOption "backups of fleet.state with rustic";

    repositories = lib.mkOption {
      type = lib.types.attrsOf toml.type;
      default = { };
      example = lib.literalExpression ''
        {
          state.repository = "/mnt/backup/state";
          data.repository = "/mnt/backup/data";
        }
      '';
      description = ''
        The `[repository]` table of the rustic profile of each kind that has
        entries to back up (`repository`, `options`, ...), without the
        password, which comes from `passwordFile`.
      '';
    };

    passwordFile = lib.mkOption {
      type = lib.types.str;
      description = "File with the password of the repositories.";
    };

    credentialFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = lib.literalExpression ''{ ssh-key = "/run/secrets/backup/ssh-key"; }'';
      description = ''
        Further files the repository options read (by their path, as given
        here), so that a restore on another host can be handed them.
      '';
    };

    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.openssh ]";
      description = "Programs the repositories' transport needs (ssh for sftp).";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "When backups run (systemd calendar event).";
    };

    retention =
      let
        periods = {
          hourly = null;
          daily = null;
          weekly = null;
          monthly = null;
          yearly = null;
        };
        kind =
          defaults:
          lib.mkOption {
            default = { };
            description = "Snapshots of this kind kept, as rustic's forget --keep-<period> (-1: all).";
            type = lib.types.submodule {
              options = lib.mapAttrs (
                period: _:
                lib.mkOption {
                  type = lib.types.nullOr lib.types.int;
                  default = defaults.${period} or null;
                  description = "Snapshots kept by ${period}.";
                }
              ) periods;
            };
          };
      in
      {
        state = kind {
          daily = 14;
          weekly = 8;
          monthly = 12;
          yearly = -1;
        };
        data = kind {
          daily = 7;
          weekly = 4;
          monthly = 6;
        };
      };

    metrics.textfileDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/prometheus-node-exporter-text-files";
      description = ''
        Where to write fleet-backup.prom for node_exporter's textfile
        collector: `fleet_backup_last_success_timestamp_seconds` and
        `fleet_backup_snapshots{kind}`.
      '';
    };

    profiles = lib.mkOption {
      type = lib.types.attrsOf toml.type;
      readOnly = true;
      default = if cfg.enable then profiles else { };
      defaultText = lib.literalMD "the rustic profile of each kind";
      description = "The rustic profiles, /etc/rustic/<kind>.toml (for `fleetl`).";
    };
  };

  config = lib.mkIf (cfg.enable && entries != { }) {
    assertions = [
      {
        assertion = lib.all (kind: cfg.repositories ? ${kind}) kinds;
        message = "fleet.backup: no repository for ${
          toString (lib.filter (kind: !(cfg.repositories ? ${kind})) kinds)
        } (fleet.backup.repositories)";
      }
      {
        assertion = !(cfg.credentialFiles ? password);
        message = "fleet.backup.credentialFiles: `password` is passwordFile's name";
      }
      {
        assertion = config.fleet.storage.tool.enable;
        message = "fleet.backup needs fleet-state (fleet.storage.tool.enable)";
      }
      {
        assertion = lib.all (
          kind: lib.any (v: v != null) (builtins.attrValues cfg.retention.${kind})
        ) kinds;
        message = "fleet.backup: every kind backed up needs a retention (fleet.backup.retention)";
      }
    ];

    fleet.storage.tool.packages = cfg.packages;

    environment.systemPackages = [ pkgs.rustic ];
    environment.etc = {
      "fleet-state/backup.json".text = builtins.toJSON {
        inherit kinds;
        # the repository tables, for a restore on another host (fleet-state access)
        repositories = lib.genAttrs kinds (kind: cfg.repositories.${kind});
        metrics = cfg.metrics.textfileDir;
        credentials = {
          password = cfg.passwordFile;
        }
        // cfg.credentialFiles;
      };
    }
    // lib.mapAttrs' (
      kind: profile:
      lib.nameValuePair "rustic/${kind}.toml" { source = toml.generate "rustic-${kind}.toml" profile; }
    ) profiles;

    systemd.services.fleet-backup = {
      description = "Backup of fleet.state";
      after = [
        "network-online.target"
        "fleet-state.service"
      ];
      # wants: a switch that restarts fleet-state must not kill a running backup
      wants = [
        "network-online.target"
        "fleet-state.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${fleetState} backup --all";
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };

    systemd.services.fleet-backup-init = {
      description = "Create the backup repositories (once per host)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${fleetState} init";
      };
    };

    systemd.timers.fleet-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };
  };
}
