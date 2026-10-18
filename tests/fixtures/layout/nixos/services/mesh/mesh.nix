{ service, lib, ... }:
{
  environment.etc."service-mesh".text = lib.concatStringsSep ":" [
    (lib.concatStringsSep "," service.role)
    (lib.concatStringsSep "," service.roles.spoke.hosts)
  ];
}
