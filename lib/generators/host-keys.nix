# The host's SSH host key and its initrd key: the public halves next to
# host.nix (ssh.pub makes the host a sops recipient), the private halves in
# identity.yaml, which `fleetl host install` puts in place.
{ pkgs }:
{
  description = "SSH host key and initrd host key";
  runtimeInputs = [ pkgs.openssh ];
  files = {
    "ssh.pub" = { };
    "initrd.pub" = { };
    "ssh_host_ed25519_key" = {
      secret = true;
      store = "identity";
    };
    "initrd_ssh_host_ed25519_key" = {
      secret = true;
      store = "identity";
    };
  };
  script = ''
    ssh-keygen -q -t ed25519 -N "" -C "$HOST" -f "$out/ssh_host_ed25519_key"
    ssh-keygen -q -t ed25519 -N "" -C "$HOST initrd" -f "$out/initrd_ssh_host_ed25519_key"
    cut -d' ' -f1,2 "$out/ssh_host_ed25519_key.pub" > "$out/ssh.pub"
    cut -d' ' -f1,2 "$out/initrd_ssh_host_ed25519_key.pub" > "$out/initrd.pub"
    rm "$out/ssh_host_ed25519_key.pub" "$out/initrd_ssh_host_ed25519_key.pub"
  '';
}
