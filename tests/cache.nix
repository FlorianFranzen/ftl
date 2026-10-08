# Cache serving test: builder signs and pushes closures into the file://
# cache, nginx serves it, a client substitutes with signature verification
# (and refuses unsigned paths). Uses a committed throwaway test keypair so
# the client's trust can be configured at eval time.
{
  pkgs,
  ftl,
  nixpkgs,
}:
let
  publicKey = pkgs.lib.fileContents ./fixtures/keys/cache-test.public;
in
pkgs.testers.runNixOSTest {
  name = "ftl-cache";

  nodes = {
    builder =
      { ... }:
      {
        imports = [ ftl.nixosModules.cache ];
        virtualisation.writableStore = true;
        nix.settings.experimental-features = [ "nix-command" ];
        environment.etc."ftl-test/cache.secret" = {
          source = ./fixtures/keys/cache-test.secret;
          mode = "0400";
        };
        ftl.cache = {
          enable = true;
          cacheDir = "/var/lib/cache";
          statusDir = "/var/lib/status";
        };
      };

    client =
      { lib, ... }:
      {
        imports = [ ftl.nixosModules.client ];
        virtualisation.writableStore = true;
        nix.settings.experimental-features = [ "nix-command" ];
        # Drop the default substituters so only the ftl cache is consulted.
        nix.settings.substituters = lib.mkForce [ ];
        ftl.client = {
          enable = true;
          substituters = [
            {
              url = "http://builder:8080/cache";
              inherit publicKey;
            }
          ];
        };
      };
  };

  testScript = ''
    start_all()
    builder.wait_for_unit("nginx.service")
    client.wait_for_unit("multi-user.target")

    mk = (
        "nix build --expr 'derivation {{ name=\"{name}\"; system=\"x86_64-linux\";"
        " builder=\"/bin/sh\"; args=[\"-c\" \"echo {name} > $out\"]; }}'"
        " -o /tmp/{name} && readlink -f /tmp/{name}"
    )

    builder.succeed("mkdir -p /var/lib/cache /var/lib/status")

    # Signed path: substitutable by the client.
    signed = builder.succeed(mk.format(name="ftl-signed")).strip()
    builder.succeed(
        f"nix copy --to 'file:///var/lib/cache?secret-key=/etc/ftl-test/cache.secret&compression=zstd' {signed}"
    )

    # Unsigned path: present in the cache but must be refused.
    unsigned = builder.succeed(mk.format(name="ftl-unsigned")).strip()
    builder.succeed(f"nix copy --to 'file:///var/lib/cache?compression=zstd' {unsigned}")

    client.succeed(f"nix-store -r {signed}")
    client.succeed(f"nix-store -q --hash {signed}")
    client.fail(f"nix-store -r {unsigned}")

    # Status dir is served as JSON.
    builder.succeed("echo '{}' > /var/lib/status/env.json")
    client.succeed("curl -fsS http://builder:8080/status/env.json")
    # Root redirects to the status listing.
    client.succeed("curl -fsS -L http://builder:8080/ >/dev/null")
  '';
}
