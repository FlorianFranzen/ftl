# fleet.comin: glue between comin (base system deployment) and ftl.
#
# comin's postDeploymentCommand runs one ftl hook that
#   1. on lanzaboote hosts, syncs comin's generation into the default `system`
#      profile and reinstalls the bootloader. comin writes generations to
#      /nix/var/nix/profiles/system-profiles/comin, but lanzaboote only builds
#      boot entries from /nix/var/nix/profiles/system (lanzaboote#541 was
#      closed unmerged), so without this a comin deployment would silently be
#      lost on reboot;
#   2. triggers ftl layer updates for the deployed commit.
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.fleet.comin;

  hasComin = options ? services && options.services ? comin;
  hasLanzaboote = options ? boot && options.boot ? lanzaboote;

  hook = pkgs.writeShellScript "ftl-comin-hook" ''
    set -u
    PATH=${
      lib.makeBinPath [
        config.nix.package
        pkgs.coreutils
        config.systemd.package
      ]
    }:$PATH

    if [ "''${COMIN_STATUS:-}" != done ]; then
      echo "ftl-comin-hook: deployment status (''${COMIN_STATUS:-unset}), nothing to do" >&2
      exit 0
    fi

    ${lib.optionalString cfg.syncSystemProfile ''
      # Only act when comin itself created a new generation (switch/boot
      # operations); never undo a manual nixos-rebuild of the system profile.
      state=/var/lib/ftl-comin
      mkdir -p "$state"
      target="$(readlink -f /nix/var/nix/profiles/system-profiles/comin 2>/dev/null || true)"
      synced="$(cat "$state/synced" 2>/dev/null || true)"
      if [ -n "$target" ] && [ "$target" != "$synced" ]; then
        if [ "$(readlink -f /nix/var/nix/profiles/system)" != "$target" ]; then
          echo "ftl-comin-hook: adding $target to the system profile for the bootloader" >&2
          nix-env --profile /nix/var/nix/profiles/system --set "$target"
          "$target/bin/switch-to-configuration" boot
        fi
        echo "$target" >"$state/synced"
      fi
    ''}

    ${lib.optionalString (config.fleet.layers.installed != { }) ''
      ${config.fleet.layers.hook}
    ''}
  '';
in
{
  imports = [
    ./layers.nix
    ./agents.nix
  ];

  options.fleet.comin = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = hasComin && config.services.comin.enable;
      defaultText = lib.literalExpression "services.comin.enable (when comin's module is imported)";
      description = "Install ftl's comin postDeploymentCommand hook.";
    };

    syncSystemProfile = lib.mkOption {
      type = lib.types.bool;
      default = hasLanzaboote && config.boot.lanzaboote.enable;
      defaultText = lib.literalExpression "boot.lanzaboote.enable";
      description = ''
        Mirror comin's generations into the default system profile and
        reinstall the bootloader after each comin switch/boot deployment.
        Needed for bootloaders that ignore system-profiles/ (lanzaboote).
      '';
    };

    hook = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = hook;
      description = "The combined hook script (for services.comin.postDeploymentCommand).";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.optionalAttrs hasComin {
      services.comin.postDeploymentCommand = lib.mkDefault hook;

      fleet.agents.sections.comin = {
        order = 50;
        text = ''
          ## Deployment

          comin deploys this host: it follows the fleet's repository and switches
          to what the deployed branch says. A local `nixos-rebuild switch` is
          undone by its next deployment; change the repository instead.
          `comin status` shows what is deployed.
        '';
      };
    }
  );
}
