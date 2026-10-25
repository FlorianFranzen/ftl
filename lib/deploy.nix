# mkDeploy: deploy-rs nodes for the fleet's hosts.
#
# Every host is reached by its address and checked against the SSH host key
# next to its host.nix (ssh.pub), so neither DNS that still points elsewhere
# (after a reinstall or rename) nor a stale entry in your own known_hosts gets
# in the way. The result is the `deploy` flake output:
#
#   deploy = ftl.lib.mkDeploy {
#     inherit (self) nixosConfigurations;
#     hosts = self.fleet.hosts;
#     deploy = inputs.deploy-rs;
#     sshUser = "admin";
#   };
#
# A host's `fqdn` (free-form host data) is its address when present
# (lib/address.nix); `address` picks something else, e.g.
# `h: h.network.ipv4.address`. Its key is pinned under its name, as the ssh
# blocks of fleet.access and fleetl pin it.
#
# The hosts' Nix daemons trust nobody but root (fleet.nix), so an `sshUser`
# other than root copies the closure through sudo (`sudoCopy`, deploy-rs
# with sudo-copy support; others ignore the setting): its sudo authenticates
# against the forwarded agent (fleet.access), and activation uses it anyway.
{
  hosts,
  nixosConfigurations,
  # the deploy-rs flake (for its activation scripts)
  deploy,
  # host data -> address to connect to
  address ? (import ./address.nix { inherit lib; }).addressOf,
  # who logs in, and who owns the system profile
  sshUser ? "root",
  user ? "root",
  sshOpts ? [ ],
  # copy the closure as root through sudo (an untrusted sshUser needs it)
  sudoCopy ? sshUser != "root",
  # hosts to leave out
  exclude ? [ ],
  # nixpkgs' lib; deploy-rs carries one
  lib ? deploy.inputs.nixpkgs.lib,
}:
let

  # Every host's SSH host key, under its name (HostKeyAlias below).
  knownHosts = builtins.toFile "fleet-known-hosts" (
    lib.concatStrings (
      lib.mapAttrsToList (name: h: lib.optionalString (h ? keys.ssh) "${name} ${h.keys.ssh}\n") hosts
    )
  );

  node =
    name: nixosConfig:
    let
      h = hosts.${name};
      system = nixosConfig.pkgs.stdenv.hostPlatform.system;
    in
    {
      hostname = address h;
      inherit sshUser;
      sshOpts =
        sshOpts
        ++ lib.optionals (h ? keys.ssh) [
          "-o"
          "HostKeyAlias=${name}"
          "-o"
          "UserKnownHostsFile=${knownHosts}"
          "-o"
          "StrictHostKeyChecking=yes"
        ];
      profiles.system = {
        inherit user;
        path = deploy.lib.${system}.activate.nixos nixosConfig;
      };
    };
in
{
  nodes = lib.mapAttrs node (
    lib.filterAttrs (name: _: hosts ? ${name} && !(builtins.elem name exclude)) nixosConfigurations
  );
  inherit sshUser knownHosts;
}
// lib.optionalAttrs sudoCopy { inherit sudoCopy; }
