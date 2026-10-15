{
  service,
  fleet,
  lib,
  ...
}:
{
  environment.etc."service-web".text = lib.concatStringsSep ":" [
    service.name
    (toString service.port)
    (lib.concatStringsSep "," service.hosts)
    (lib.concatStringsSep "," fleet.self.services)
  ];
}
