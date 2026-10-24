# Binary caches: a cache is announced as `cache = { publicKeys; url?; port?;
# statusUrl?; }` in a host.nix (served by that host) or a service.nix (by each
# of its hosts). `fleet.caches` lists them once per serving host; fleet.client
# substitutes from them.
ctx:
let
  inherit (ctx)
    lib
    name
    peers
    serviceInfo
    ;

  # Every cache the fleet announces, once per host serving it (`fleet.caches`).
  cacheOn =
    where: hostName: c:
    let
      base = "http://${peers.${hostName}.fqdn or hostName}:${toString (c.port or 8080)}";
    in
    assert lib.assertMsg (
      builtins.isList (c.publicKeys or null) && c.publicKeys != [ ]
    ) "ftl: ${where}: `cache` needs `publicKeys`, the cache's signing keys (name:base64)";
    {
      host = hostName;
      url = c.url or "${base}/cache";
      # the builder publishes <rootDir>/status/<repo name>.json; the fleet's name by convention
      statusUrl = c.statusUrl or (if c ? url then null else "${base}/status/${name}.json");
      inherit (c) publicKeys;
    };
in
{
  caches =
    lib.concatLists (
      lib.mapAttrsToList (h: p: lib.optional (p ? cache) (cacheOn "host '${h}'" h p.cache)) peers
    )
    ++ lib.concatLists (
      lib.mapAttrsToList (
        s: si: lib.optionals (si ? cache) (map (h: cacheOn "service '${s}'" h si.cache) si.hosts)
      ) serviceInfo
    );
}
