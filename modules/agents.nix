# fleet.agents: /etc/AGENTS.md, what an agent working on this host must know.
#
# The head is this host's part of the repository's AGENTS.md (lib/agents.nix,
# from the fleet's metadata); every ftl module that changes how the host is
# operated adds a section (`fleet.agents.sections`), and so can any other.
#
# Standalone (without the `fleet` argument) only the sections are written.
{
  config,
  lib,
  ...
}@args:

let
  cfg = config.fleet.agents;
  meta = config.fleet.meta;
  fleet = args.fleet or null;
  render = import ../lib/agents.nix { inherit lib; };

  head =
    if fleet != null && meta.host != null then
      render.host {
        name = if meta.environment != null then meta.environment else "nixos";
        inherit (meta) repo;
        inherit (fleet) hosts services users;
        caches = fleet.caches or [ ];
        hostName = meta.host;
      }
    else
      "# AGENTS.md: ${config.networking.hostName}\n";

  sections = lib.sort (a: b: a.order < b.order || (a.order == b.order && a.name < b.name)) (
    lib.mapAttrsToList (name: s: s // { inherit name; }) (
      lib.filterAttrs (_: s: s.text != "") cfg.sections
    )
  );
in
{
  imports = [ ./meta.nix ];

  options.fleet.agents = {
    enable = lib.mkEnableOption "/etc/AGENTS.md, a guide to this host for agents (set by ftl.lib.mkNixos)";

    sections = lib.mkOption {
      default = { };
      description = ''
        Sections of /etc/AGENTS.md after the host's metadata, by `order`: what
        an agent must know about how this host is operated (who deploys it,
        which units not to touch, what needs a person).
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            order = lib.mkOption {
              type = lib.types.int;
              default = 100;
            };
            text = lib.mkOption {
              type = lib.types.lines;
              description = "Markdown, starting with its own `##` heading.";
            };
          };
        }
      );
    };

    text = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = lib.concatStringsSep "\n" (
        [ head ] ++ map (s: lib.removeSuffix "\n" s.text + "\n") sections
      );
      defaultText = lib.literalMD "the host's metadata and the sections";
      description = "The rendered /etc/AGENTS.md.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."AGENTS.md".text = cfg.text;
  };
}
