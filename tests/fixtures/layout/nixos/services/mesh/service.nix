# A service with two sides, and a layer every one of its hosts gets.
{
  roles.hub.hosts = [ "alpha" ];
  roles.spoke.hosts = [
    "beta"
    "gamma"
  ];
  layers = [ "tools" ];
}
