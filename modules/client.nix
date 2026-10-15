# fleet.client: binary cache and gc wiring shared by every host of an ftl
# environment. Deployment itself is comin's job (base system) and
# fleet.layers' job (layers).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.client;
  scripts = import ./scripts.nix { inherit pkgs; };

  ftl-status = pkgs.writeShellScriptBin "ftl-status" ''
    if [ -z "''${FTL_STATUS_URL:-}" ]; then FTL_STATUS_URL=${lib.escapeShellArg cfg.statusUrl}; fi
    if [ -z "''${FTL_REPO_URL:-}" ]; then FTL_REPO_URL=${lib.escapeShellArg (toString cfg.repo)}; fi
    export FTL_STATUS_URL FTL_REPO_URL
    exec ${lib.getExe scripts.ftl-status} "$@"
  '';
in
{
  imports = [ ./meta.nix ];

  options.fleet.client = {
    enable = lib.mkEnableOption "ftl client wiring";

    substituters = lib.mkOption {
      default = [ ];
      description = "Binary caches this host substitutes from.";
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            url = lib.mkOption { type = lib.types.str; };
            publicKey = lib.mkOption { type = lib.types.str; };
          };
        }
      );
    };

    connectTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "nix substituter connect timeout (fast off-LAN fallback).";
    };

    gc = {
      automatic = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      dates = lib.mkOption {
        type = lib.types.str;
        default = "weekly";
      };
      options = lib.mkOption {
        type = lib.types.str;
        default = "--delete-older-than 30d";
      };
    };

    repo = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Environment repository URL (ftl-status fallback when the status page is unreachable).";
    };

    statusUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "http://pavlov.lan:8080/status/nixrc.json";
      description = "Builder status JSON endpoint used by ftl-status.";
    };
  };

  config = lib.mkIf cfg.enable {
    nix.settings = lib.mkIf (cfg.substituters != [ ]) {
      extra-substituters = map (s: s.url) cfg.substituters;
      extra-trusted-public-keys = map (s: s.publicKey) cfg.substituters;
      connect-timeout = lib.mkDefault cfg.connectTimeout;
      fallback = lib.mkDefault true;
    };

    nix.gc = {
      automatic = lib.mkDefault cfg.gc.automatic;
      dates = lib.mkDefault cfg.gc.dates;
      options = lib.mkDefault cfg.gc.options;
    };

    environment.systemPackages = lib.mkIf (cfg.statusUrl != null || cfg.repo != null) [ ftl-status ];
  };
}
