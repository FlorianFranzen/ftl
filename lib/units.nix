# Pieces ftl's own units and options share (the pipeline, the layer updater).
{ lib }:
{
  # nix for ftl's own scripts, whatever the host's nix.conf says
  nixConfig = "experimental-features = nix-command flakes";

  # Sandboxing of a service that writes only the trees in ReadWritePaths and
  # otherwise reaches nix-daemon's socket and the network.
  hardening = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
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

  # verify = { mode; allowedSignersFile; gpgHome; }: which commits are trusted
  # (FTL_VERIFY_* for scripts/lib/common.sh's verify_commit)
  verifyOptions = modeDescription: {
    mode = lib.mkOption {
      type = lib.types.enum [
        "none"
        "ssh"
        "gpg"
      ];
      default = "none";
      description = modeDescription;
    };
    allowedSignersFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "OpenSSH allowed_signers file (ssh mode).";
    };
    gpgHome = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "GNUPGHOME whose keyring holds exactly the trusted public keys (gpg mode).";
    };
  };
}
