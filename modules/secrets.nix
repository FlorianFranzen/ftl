# fleet.secrets: the host's secret store, nixos/hosts/<host>/secrets.yaml,
# decrypted by sops-nix with the host's SSH host key (its ssh-to-age form is
# the store's recipient), or with the age key at `ageKeyFile` for a host that
# has a `sops.age` next to its host.nix instead. The fleet's shared store,
# nixos/secrets.yaml, is `shared`; every host is a recipient of it.
#
# Services keep their secrets in their own folder: `service.sopsFile` in a
# service module is nixos/services/<service>/secrets.yaml, so
#
#   sops.secrets."db/password".sopsFile = service.sopsFile;
#
# needs no path. The recipients of every store follow from the layout (see
# `fleet.sops` in the flake outputs); `fleetl secrets sync` writes .sops.yaml
# from them.
#
# Only active when sops-nix's module is imported (mkFlake does that when the
# flake has a `sops-nix` input).
{
  config,
  lib,
  options,
  ...
}:

let
  cfg = config.fleet.secrets;
  hasSops = options ? sops;
in
{
  options.fleet.secrets = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = hasSops;
      defaultText = lib.literalExpression "true when sops-nix's module is imported";
      description = "Wire sops-nix to the host's store and key.";
    };

    file = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "The host's secret store (set by ftl.lib.mkNixos when the file exists).";
    };

    shared = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        The fleet's shared store, nixos/secrets.yaml, which every host can read
        (set by ftl.lib.mkNixos when the file exists); a secret of it is
        `sops.secrets.<name>.sopsFile = config.fleet.secrets.shared`.
      '';
    };

    ageKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Age key the host decrypts with instead of its SSH host key; set by
        ftl.lib.mkNixos to /var/lib/sops-nix/key.txt for hosts with a sops.age.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.optionalAttrs hasSops {
      sops = {
        defaultSopsFile = lib.mkIf (cfg.file != null) (lib.mkDefault cfg.file);
        age.keyFile = lib.mkIf (cfg.ageKeyFile != null) (lib.mkDefault cfg.ageKeyFile);
        # age only: sops-nix would otherwise import the RSA host key into gnupg
        gnupg.sshKeyPaths = lib.mkDefault [ ];
      };
    }
  );
}
