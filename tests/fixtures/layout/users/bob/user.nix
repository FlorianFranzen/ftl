# Only on the hosts of the web service, in one extra group.
{
  services = [ "web" ];
  uid = 1001;
  groups = [ "video" ];
}
