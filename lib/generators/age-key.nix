# A dedicated age key for a host that should not decrypt with its SSH host
# key: the recipient as sops.age next to host.nix, the key in identity.yaml
# (installed at /var/lib/sops-nix/key.txt).
{ pkgs }:
{
  description = "dedicated age key instead of the SSH host key";
  runtimeInputs = [ pkgs.age ];
  files = {
    "sops.age" = { };
    "age_key" = {
      secret = true;
      store = "identity";
    };
  };
  script = ''
    age-keygen -o "$out/age_key" 2>/dev/null
    grep '^# public key:' "$out/age_key" | cut -d' ' -f4 > "$out/sops.age"
  '';
}
