# The host's WireGuard key pair: the public key next to host.nix
# (fleet.hosts.<h>.keys.wireguard), the private one as wireguard/private in
# its secret store. List `wireguard` in a host's `generators` to use it.
{ pkgs }:
{
  description = "WireGuard key pair for the mesh";
  runtimeInputs = [ pkgs.wireguard-tools ];
  files = {
    "wireguard.pub" = { };
    private = {
      secret = true;
    };
  };
  script = ''
    wg genkey > "$out/private"
    wg pubkey < "$out/private" > "$out/wireguard.pub"
  '';
}
