# fleet.client: binary cache and gc wiring shared by every host of an ftl
# environment. Deployment itself is comin's job (base system) and
# fleet.layers' job (layers).
#
# The caches the fleet announces (`cache` in a host.nix or service.nix, see
# mkNixos) are substituters of every other host; mkNixos turns the module on
# where there is one.
{
  config,
  lib,
  pkgs,
  ...
}@args:
let
  cfg = config.fleet.client;
  fleet = args.fleet or null;

  # the fleet's caches, except the ones this host serves itself
  fleetCaches = lib.optionals (fleet != null && cfg.fleetCaches) (
    lib.filter (c: c.host != config.fleet.meta.host) (fleet.caches or [ ])
  );
  withStatus = lib.filter (c: c.statusUrl != null) fleetCaches;

  urls = map (s: s.url) cfg.substituters ++ map (c: c.url) fleetCaches;
  publicKeys = lib.unique (
    map (s: s.publicKey) cfg.substituters ++ lib.concatMap (c: c.publicKeys) fleetCaches
  );
  scripts = import ./scripts.nix { inherit pkgs; };

  ftl-status = pkgs.writeShellScriptBin "ftl-status" ''
    if [ -z "''${FTL_STATUS_URL:-}" ]; then FTL_STATUS_URL=${lib.escapeShellArg cfg.statusUrl}; fi
    if [ -z "''${FTL_REPO_URL:-}" ]; then FTL_REPO_URL=${lib.escapeShellArg (toString cfg.repo)}; fi
    export FTL_STATUS_URL FTL_REPO_URL
    exec ${lib.getExe scripts.ftl-status} "$@"
  '';
in
{
  imports = [
    ./meta.nix
    ./agents.nix
  ];

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

    fleetCaches = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Substitute from the binary caches the fleet announces (`cache` in a
        host.nix or service.nix), besides `substituters`. A host never uses the
        ones it serves itself.
      '';
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
      default = if withStatus != [ ] then (builtins.head withStatus).statusUrl else null;
      defaultText = lib.literalMD "the status page of the first fleet cache that has one";
      example = "http://pavlov.lan:8080/status/nixrc.json";
      description = "Builder status JSON endpoint used by ftl-status.";
    };
  };

  config = lib.mkIf cfg.enable {
    nix.settings = lib.mkIf (urls != [ ]) {
      extra-substituters = urls;
      extra-trusted-public-keys = publicKeys;
      connect-timeout = lib.mkDefault cfg.connectTimeout;
      fallback = lib.mkDefault true;
    };

    nix.gc = {
      automatic = lib.mkDefault cfg.gc.automatic;
      dates = lib.mkDefault cfg.gc.dates;
      options = lib.mkDefault cfg.gc.options;
    };

    environment.systemPackages = lib.mkIf (cfg.statusUrl != null || cfg.repo != null) [ ftl-status ];

    fleet.agents.sections.client = lib.mkIf (urls != [ ]) {
      order = 60;
      text = ''
        ## Binary caches

        This host substitutes from ${lib.concatMapStringsSep ", " (u: "`${u}`") urls}, falling back to
        building when they are unreachable.${
          lib.optionalString (
            cfg.statusUrl != null || cfg.repo != null
          ) " `ftl-status` shows what the fleet's builder built last."
        }
      '';
    };
  };
}
