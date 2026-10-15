# The service's state: a subvolume of its own, mounted before its unit starts.
{ service, ... }:
{
  fleet.storage.btrfsDevice = "/dev/disk/by-label/root";
  fleet.state.web = {
    path = "/var/lib/web";
    units = [ "web" ];
    service = service.name;
  };
  fleet.state.web-cache = {
    path = "/srv/web-cache";
    kind = "data";
  };
}
