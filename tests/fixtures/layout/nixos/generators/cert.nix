# A host generator with inputs: a certificate for the host, signed by the
# fleet's CA (made first if missing), named after its SSH host key.
{ pkgs }:
{
  description = "a certificate signed by the fleet's CA";
  inputs = [
    "ca/ca.pub"
    "ca/ca.key"
    "host-keys/ssh.pub"
  ];
  runtimeInputs = [
    pkgs.openssl
    pkgs.coreutils
  ];
  files = {
    "cert.pub" = { };
    "cert.key" = {
      secret = true;
    };
  };
  script = ''
    openssl req -new -newkey ed25519 -nodes -subj "/CN=$HOST" \
      -keyout "$out/cert.key" -out "$out/cert.csr" 2>/dev/null
    openssl x509 -req -in "$out/cert.csr" -CA "$in/ca/ca.pub" -CAkey "$in/ca/ca.key" \
      -days 365 -out "$out/cert.pub" 2>/dev/null
    rm "$out/cert.csr"
    # the host key it was made for, as a comment
    { echo "# $(cut -d' ' -f1,2 "$in/host-keys/ssh.pub")"; cat "$out/cert.pub"; } > "$out/cert.pub.tmp"
    mv "$out/cert.pub.tmp" "$out/cert.pub"
  '';
}
