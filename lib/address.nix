# How a host is reached, the same for the ssh blocks (fleet.access), mkDeploy,
# the caches and fleetl: by its fqdn when its host.nix has one, else by its
# name; its SSH host key is known under its name (HostKeyAlias) and fqdn.
{ lib }:
{
  # names a host's key is known under in known_hosts
  namesOf = name: h: [ name ] ++ lib.optional (h ? fqdn) h.fqdn;

  # where to connect to, unless told otherwise
  addressOf = h: h.fqdn or h.name;
}
