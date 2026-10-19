{
  layers = [
    "tools"
    "svc"
  ];

  # free-form host data, visible to every host through `fleet.hosts`
  fqdn = "alpha.example.org";
  roles = [ "web" ];
}
