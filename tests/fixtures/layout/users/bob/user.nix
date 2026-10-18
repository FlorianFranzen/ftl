# Only on the hosts of the web service, in one extra group.
{
  services = [ "web" ];
  uid = 1001;
  groups = [ "video" ];
  # a home per host; `default` would cover the rest
  home.alpha = "terminal-dark";
}
