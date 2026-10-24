# fleet.layers: host side of ftl layers - independently versioned Nix profiles
# under /nix/var/nix/profiles/layers/<name>, combined with the base system at
# runtime:
#   - packages layers are added to environment.profiles (PATH, XDG_DATA_DIRS, ...)
#   - units layers ship unit files, linked in by a systemd generator, so
#     updating a layer needs only daemon-reload + restart, no system rebuild
#   - ftl-layers update resolves each layer's revision from ftl-layers.json
#     at the deployed commit (comin hook) or on a timer
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.layers;
  scripts = import ./scripts.nix { inherit pkgs; };
  kinds = import ../lib/kinds.nix lib;
  installed = lib.mapAttrs (
    n: l: l // { kind = kinds.check "layer '${n}'" l.kind; }
  ) cfg.installed;

  profileDir = "/nix/var/nix/profiles/layers";

  layerNames = builtins.attrNames installed;
  packageLayers = builtins.attrNames (lib.filterAttrs (_: l: l.kind == "packages") installed);
  unitLayers = builtins.attrNames (lib.filterAttrs (_: l: l.kind == "units") installed);

  toolEnv = lib.filterAttrs (_: v: v != null) {
    FTL_REPO_URL = cfg.repo;
    FTL_SYSTEM = pkgs.stdenv.hostPlatform.system;
    FTL_LAYERS = lib.concatStringsSep " " (lib.mapAttrsToList (n: l: "${n}:${l.kind}") installed);
    FTL_STATE_DIR = cfg.stateDir;
    FTL_PROFILE_DIR = profileDir;
    FTL_KEEP_GENERATIONS = toString cfg.keepGenerations;
    FTL_VERIFY_MODE = cfg.verify.mode;
    FTL_ALLOWED_SIGNERS =
      if cfg.verify.allowedSignersFile != null then toString cfg.verify.allowedSignersFile else null;
    FTL_GPG_HOME = if cfg.verify.gpgHome != null then toString cfg.verify.gpgHome else null;
    FTL_NTFY_URL = cfg.ntfyUrl;
  };

  # Host defaults baked in; explicitly set environment variables win.
  ftl-layers = pkgs.writeShellScriptBin "ftl-layers" ''
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (n: v: ''
        if [ -z "''${${n}:-}" ]; then ${n}=${lib.escapeShellArg v}; fi
        export ${n}
      '') toolEnv
    )}
    exec ${lib.getExe scripts.ftl-layers} "$@"
  '';

  # Link unit files of installed units layers into the generator output
  # (/etc/systemd/system is read-only on NixOS). Re-run on daemon-reload.
  generator = pkgs.writeShellScript "ftl-layers-generator" ''
    out="$1"
    for name in ${lib.escapeShellArgs unitLayers}; do
      unitdir="${profileDir}/$name/lib/systemd/system"
      [ -d "$unitdir" ] || continue
      for f in "$unitdir"/*; do
        b="''${f##*/}"
        case "$b" in
          *.wants|*.requires)
            ${pkgs.coreutils}/bin/mkdir -p "$out/$b"
            for w in "$f"/*; do
              [ -e "$w" ] || continue
              ${pkgs.coreutils}/bin/ln -sf "$unitdir/''${w##*/}" "$out/$b/''${w##*/}"
            done
            ;;
          *) ${pkgs.coreutils}/bin/ln -sf "$f" "$out/$b" ;;
        esac
      done
    done
  '';
in
{
  imports = [ ./agents.nix ];

  options.fleet.layers = {
    installed = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.kind = lib.mkOption {
            type = lib.types.enum kinds.all;
            default = "packages";
          };
        }
      );
      default = { };
      description = "Layers installed on this host (set by ftl.lib.mkNixos).";
    };

    repo = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://github.com/example/infra.git";
      description = "Environment repository the layers are built from.";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/ftl-layers";
      description = "Updater state (git mirror, target revision, layer status).";
    };

    keepGenerations = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Generations kept per layer profile.";
    };

    timer = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Periodically retry layer updates for the last deployed revision.";
      };
      dates = lib.mkOption {
        type = lib.types.str;
        default = "daily";
      };
    };

    ntfyUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "ntfy topic URL for layer update failures.";
    };

    verify = {
      mode = lib.mkOption {
        type = lib.types.enum [
          "none"
          "ssh"
          "gpg"
        ];
        default = "none";
        description = ''
          Signature verification of the target commit. Under comin this is
          redundant but cheap; it matters for manual and timer updates.
        '';
      };
      allowedSignersFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
      };
      gpgHome = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
      };
    };

    hook = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${ftl-layers}/bin/ftl-layers hook";
      description = "Command that triggers a layer update for the deployed commit (called by fleet.comin).";
    };
  };

  config = lib.mkIf (layerNames != [ ]) (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.repo != null;
            message = "fleet.layers.repo must be set on hosts with layers";
          }
        ];

        environment.profiles = lib.mkAfter (map (n: "${profileDir}/${n}") packageLayers);

        systemd.generators = lib.mkIf (unitLayers != [ ]) { ftl-layers = generator; };

        systemd.tmpfiles.rules = [ "d ${profileDir} 0755 root root -" ];

        environment.systemPackages = [ ftl-layers ];

        systemd.services.ftl-layers-update = {
          description = "Update ftl layers";
          path = [
            config.nix.package
            pkgs.git
            pkgs.openssh
          ];
          environment = {
            NIX_CONFIG = "experimental-features = nix-command flakes";
            # Root would otherwise open /nix/store directly, which the
            # sandbox below makes read-only; the daemon does the writing.
            NIX_REMOTE = "daemon";
            # Fetcher and eval caches (/root is read-only under the sandbox).
            XDG_CACHE_HOME = "${cfg.stateDir}/cache";
          };
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${ftl-layers}/bin/ftl-layers update";

            # Runs as root (profiles under /nix/var and systemctl), so confine
            # it to what it needs: its state and the layer profiles.
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectSystem = "strict";
            ReadWritePaths = [
              cfg.stateDir
              profileDir
            ];
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            RestrictSUIDSGID = true;
            RestrictRealtime = true;
            LockPersonality = true;
            SystemCallArchitectures = "native";
          };
        };

        systemd.timers.ftl-layers-update = lib.mkIf cfg.timer.enable {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.timer.dates;
            Persistent = true;
            RandomizedDelaySec = "1h";
          };
        };

        fleet.agents.sections.layers = {
          order = 40;
          text = ''
            ## Layers

            This host's layers (${lib.concatMapStringsSep ", " (n: "`${n}`") layerNames}) are Nix
            profiles under `${profileDir}/`, updated without a system rebuild, to
            the revision `ftl-layers.json` names. `ftl-layers list` shows them, `ftl-layers
            update` installs the deployed revision and `ftl-layers rollback <layer>`
            goes back one generation; never change these profiles with `nix-env`.
          '';
        };
      }
    ]
  );
}
