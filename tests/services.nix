# fleet.secrets with sops-nix for real: the host decrypts its own store and a
# service's store with its SSH host key, converted to an age recipient with
# ssh-to-age, and no age key file installed anywhere.
#
# The stores are encrypted at build time to the age form of nixpkgs' snake-oil
# ed25519 key, which the VM installs as its host key before sops-nix runs.
{
  pkgs,
  ftl,
  sops-nix,
}:
let
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;

  # a sops store, encrypted to the host key's age recipient
  store =
    name: text:
    pkgs.runCommand "${name}.yaml"
      {
        nativeBuildInputs = [
          pkgs.sops
          pkgs.ssh-to-age
        ];
        inherit text;
        passAsFile = [ "text" ];
      }
      ''
        recipient=$(echo '${keys.snakeOilEd25519PublicKey}' | ssh-to-age)
        sops --encrypt --age "$recipient" --input-type yaml --output-type yaml "$textPath" > "$out"
      '';

  hostStore = store "host" ''
    token: host-secret
  '';
  serviceStore = store "service" ''
    web:
      key: service-secret
  '';
in
pkgs.testers.runNixOSTest {
  name = "ftl-services";

  nodes.machine =
    { ... }:
    {
      imports = [
        sops-nix.nixosModules.sops
        ftl.nixosModules.secrets
      ];

      services.openssh.enable = true;

      # The stores are built, not files in the repository; sops-nix would only
      # accept path literals (the manifest check still validates them).
      sops.validateSopsFiles = false;

      # what mkNixos sets from nixos/hosts/<host>/secrets.yaml
      fleet.secrets.file = hostStore;
      sops.secrets.token = { };
      # what a service module sets from `service.sopsFile`
      sops.secrets."web/key".sopsFile = serviceStore;

      # the host key, in place before sops-nix decrypts
      system.activationScripts = {
        hostKey = {
          deps = [ "specialfs" ];
          text = ''
            install -D -m 0600 ${keys.snakeOilEd25519PrivateKey} /etc/ssh/ssh_host_ed25519_key
          '';
        };
        setupSecrets.deps = [ "hostKey" ];
      };
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    with subtest("the host store is decrypted with the SSH host key"):
        assert machine.succeed("cat /run/secrets/token").strip() == "host-secret"
        machine.fail("test -e /var/lib/sops-nix/key.txt")

    with subtest("a service store is decrypted the same way"):
        assert machine.succeed("cat /run/secrets/web/key").strip() == "service-secret"
  '';
}
