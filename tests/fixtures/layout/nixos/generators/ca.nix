# A fleet generator: one CA for the whole fleet, its certificate public
# (fleet.keys.ca), its key in nixos/identity.yaml.
{ pkgs }:
{
  description = "the fleet's CA";
  scope = "fleet";
  runtimeInputs = [ pkgs.openssl ];
  files = {
    "ca.pub" = { };
    "ca.key" = {
      secret = true;
      store = "identity";
    };
  };
  script = ''
    openssl req -x509 -newkey ed25519 -nodes -subj "/CN=fleet CA" -days 3650 \
      -keyout "$out/ca.key" -out "$out/ca.pub" 2>/dev/null
  '';
}
