# A service module: imported on the hosts of service.nix, with `service`
# (its metadata) and `fleet` (every host, service and user) as arguments.
{ service, static, ... }:
{
  environment.etc."motd".source = static.motd;
  environment.etc."motd-service".text = "${service.name} runs on ${toString service.hosts}";
}
