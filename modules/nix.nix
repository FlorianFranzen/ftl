# fleet.nix: the Nix settings every host of a fleet wants.
#
# Flakes on, since the fleet is one; no channels, since NIX_PATH and the
# registry point at the flake's inputs (modules/flake.nix). Nobody but root is
# trusted by the daemon: closures the fleet's builder built carry its cache
# signature, which every host trusts (fleet.client), and one built elsewhere
# is pushed through sudo, authenticated by the admin's forwarded agent
# (lib/agents.nix `pushCommand`, which AGENTS.md and the README show).
# Off standalone; mkNixos turns it on.
{
  config,
  lib,
  options,
  ...
}:
let
  cfg = config.fleet.nix;

  # where a @wheel in trusted-users comes from (best effort: definitions
  # wrapped in mkIf or mkMerge are not looked into)
  wheelFrom = map (d: d.file) (
    lib.filter (
      d:
      builtins.isAttrs d.value
      && builtins.isList (d.value.trusted-users or null)
      && builtins.elem "@wheel" d.value.trusted-users
    ) options.nix.settings.definitionsWithLocations
  );
in
{
  options.fleet.nix = {
    enable = lib.mkEnableOption "the fleet's Nix defaults (set by ftl.lib.mkNixos)";

    trustWheel = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        `@wheel` in nix.settings.trusted-users (next to root, which NixOS
        always adds). A trusted user is root-equivalent toward the store
        without authenticating: any process running as an admin could import
        crafted paths. Without it, admins push unsigned closures through
        `sudo nix-daemon` (`nix copy --no-check-sigs` to an ssh-ng store with
        `remote-program=sudo%20nix-daemon`), which costs their forwarded
        agent's signature (pam_rssh).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # a plain `trusted-users = [ "@wheel" ]` elsewhere merges in and undoes this
    warnings =
      lib.optional (!cfg.trustWheel && builtins.elem "@wheel" config.nix.settings.trusted-users)
        "fleet.nix: nix.settings.trusted-users contains @wheel${
          lib.optionalString (wheelFrom != [ ]) " (from ${lib.concatStringsSep ", " wheelFrom})"
        } although fleet.nix.trustWheel is false. If admins still need it (deploy-rs with a non-root sshUser and no sudoCopy, plain nixos-rebuild --target-host), replace that line with fleet.nix.trustWheel = true; otherwise drop it and push unsigned closures through sudo (README, fleet.nix).";
    nix.settings = {
      experimental-features = lib.mkDefault [
        "nix-command"
        "flakes"
      ];
      # a list merges with NixOS' own [ "root" ], so this is a plain definition
      trusted-users = lib.mkIf cfg.trustWheel [ "@wheel" ];
    };
    nix.channel.enable = lib.mkDefault false;
  };
}
