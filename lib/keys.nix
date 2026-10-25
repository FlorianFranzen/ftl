# Reading the key files next to host.nix and user.nix (ssh.pub, initrd.pub,
# sops.age, sops.pgp, a certificate): one entry per line, comments and
# empty lines ignored.
{ lib }:
rec {
  # The entries of a file, or none when it does not exist.
  lines =
    file:
    if builtins.pathExists file then
      lib.filter (l: l != "" && !lib.hasPrefix "#" l) (
        map lib.trim (lib.splitString "\n" (builtins.readFile file))
      )
    else
      [ ];

  # A public key file's value: its first entry (an SSH key, an age
  # recipient), or, for a PEM file (a certificate), every PEM line, as the PEM
  # text. null for an empty or missing file.
  readKey =
    file:
    let
      entries = lines file;
    in
    if entries == [ ] then
      null
    else if lib.hasPrefix "-----BEGIN " (builtins.head entries) then
      lib.concatMapStrings (l: l + "\n") entries
    else
      builtins.head entries;
}
