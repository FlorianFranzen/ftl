# ftl.cache: serve the pipeline's file:// binary cache and status pages
# over HTTP (plain nginx static hosting; NAR signatures carry the trust).
{
  config,
  lib,
  ...
}:
let
  cfg = config.ftl.cache;
  rootDir = config.ftl.rootDir;
in
{
  imports = [ ./dirs.nix ];

  options.ftl.cache = {
    enable = lib.mkEnableOption "the ftl binary cache webserver";

    cacheDir = lib.mkOption {
      type = lib.types.path;
      default = "${rootDir}/cache";
      defaultText = lib.literalExpression ''"''${config.ftl.rootDir}/cache"'';
      description = "Directory holding the nix binary cache (narinfo/nar layout).";
    };
    statusDir = lib.mkOption {
      type = lib.types.path;
      default = "${rootDir}/status";
      defaultText = lib.literalExpression ''"''${config.ftl.rootDir}/status"'';
      description = "Directory holding pipeline status JSON.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "HTTP port.";
    };
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the HTTP port in the firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.nginx = {
      enable = true;
      recommendedGzipSettings = lib.mkDefault false; # NARs are pre-compressed
      virtualHosts."ftl-cache" = {
        listen = [
          {
            addr = "0.0.0.0";
            port = cfg.port;
          }
          {
            addr = "[::]";
            port = cfg.port;
          }
        ];
        locations."/cache/" = {
          alias = "${cfg.cacheDir}/";
          extraConfig = ''
            autoindex off;
          '';
        };
        locations."/status/" = {
          alias = "${cfg.statusDir}/";
          extraConfig = ''
            autoindex on;
            types { } default_type "application/json";
          '';
        };
        locations."= /" = {
          return = "302 /status/";
        };
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
