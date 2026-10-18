# A secret from the service's own store.
{ service, ... }:
{
  sops.secrets."web/token".sopsFile = service.sopsFile;
}
