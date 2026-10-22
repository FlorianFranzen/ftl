# A TLS certificate for the host, signed by the fleet's CA (fleet-ca, made
# first if missing): for the host's name, good as a server and as a client,
# so that services between the hosts can authenticate both ends.  The
# certificate as tls.pub next to host.nix (fleet.hosts.<h>.keys.tls), the key
# in the host's store as host-tls/tls.key.  Valid five years; run the
# generator again (fleetl host generate --force <h> host-tls) to renew.
{ pkgs }:
{
  description = "the host's TLS certificate, signed by the fleet's CA";
  inputs = [
    "fleet-ca/fleet-ca.pub"
    "fleet-ca/fleet-ca.key"
  ];
  runtimeInputs = [
    pkgs.openssl
    pkgs.coreutils
  ];
  files = {
    "tls.pub" = { };
    "tls.key" = {
      secret = true;
    };
  };
  script = ''
    (umask 077; openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/tls.key")
    openssl req -new -key "$out/tls.key" -subj "/CN=$HOST" -out "$out/tls.csr"
    printf '%s\n' \
      "subjectAltName=DNS:$HOST" \
      "basicConstraints=critical,CA:FALSE" \
      "keyUsage=critical,digitalSignature" \
      "extendedKeyUsage=serverAuth,clientAuth" >"$out/tls.ext"
    openssl x509 -req -in "$out/tls.csr" -CA "$in/fleet-ca/fleet-ca.pub" -CAkey "$in/fleet-ca/fleet-ca.key" \
      -days 1825 -extfile "$out/tls.ext" -out "$out/tls.pub"
    rm "$out/tls.csr" "$out/tls.ext"
  '';
}
