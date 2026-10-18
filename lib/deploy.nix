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
# A host's `fqdn` (free-form host data) is its address and known_hosts name
# when present; `address` picks something else, e.g. `h: h.network.ipv4.address`.
{
  hosts,
  nixosConfigurations,
  # the deploy-rs flake (for its activation scripts)
  deploy,
  # host data -> address to connect to
  address ? (h: h.fqdn or h.name),
  # who logs in, and who owns the system profile
  sshUser ? "root",
  user ? "root",
  sshOpts ? [ ],
  # hosts to leave out
  exclude ? [ ],
}:
let
  lib = deploy.inputs.nixpkgs.lib or (import <nixpkgs> { }).lib;

  # Every host's SSH host key, under the name HostKeyAlias uses below.
  knownHosts = builtins.toFile "fleet-known-hosts" (
    lib.concatStrings (
      lib.mapAttrsToList (
        name: h: lib.optionalString (h ? keys.ssh) "${h.fqdn or name} ${h.keys.ssh}\n"
      ) hosts
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
          "HostKeyAlias=${h.fqdn or name}"
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
