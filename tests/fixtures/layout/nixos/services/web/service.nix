# Service metadata (not a module): where it runs, plus free-form data.
{
  hosts = [ "alpha" ];
  port = 8080;
  # a binary cache served by every host of the service (fleet.caches)
  cache.publicKeys = [ "ftl-test-1:6CA2VCkcTQDS8JL6HcoXOOHZWCqjV+3baLKM86c7dcw=" ];
}
