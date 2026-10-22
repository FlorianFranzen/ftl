# The fleet's own certificate authority, made once for the whole fleet: its
# certificate as nixos/fleet-ca.pub (every host sees it as
# fleet.keys.fleet-ca), its key in nixos/identity.yaml, which only the admins
# can read.  host-tls signs each host's certificate with it.
{ pkgs }:
{
  description = "the fleet's certificate authority (for TLS between the hosts)";
  scope = "fleet";
  runtimeInputs = [ pkgs.openssl ];
  files = {
    "fleet-ca.pub" = { };
    "fleet-ca.key" = {
      secret = true;
      store = "identity";
    };
  };
  script = ''
    (umask 077; openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/fleet-ca.key")
    openssl req -x509 -new -key "$out/fleet-ca.key" -subj "/CN=fleet CA" -days 3650 \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -out "$out/fleet-ca.pub"
  '';
}
