# Minimal stand-in for the sops-nix flake: the options ftl's secrets module
# sets, and `sops.secrets` for modules to declare, without decrypting anything.
{
  nixosModules.sops =
    { lib, ... }:
    {
      options.sops = {
        defaultSopsFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
        };
        age.keyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
        };
        age.sshKeyPaths = lib.mkOption {
          type = lib.types.listOf lib.types.path;
          default = [ "/etc/ssh/ssh_host_ed25519_key" ];
        };
        gnupg.sshKeyPaths = lib.mkOption {
          type = lib.types.listOf lib.types.path;
          default = [ "/etc/ssh/ssh_host_rsa_key" ];
        };
        secrets = lib.mkOption {
          type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
          default = { };
        };
      };
    };
}
