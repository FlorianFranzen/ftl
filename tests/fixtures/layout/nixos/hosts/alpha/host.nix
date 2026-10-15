{
  layers = [
    "tools"
    "svc"
  ];

  # free-form host data, visible to every host through `peers`
  fqdn = "alpha.example.org";
  roles = [ "web" ];
}
