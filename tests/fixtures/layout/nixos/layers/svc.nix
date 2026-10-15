{
  kind = "units";
  packages = pkgs: [ pkgs.hello-ftl ];
  units.ftl-demo = {
    description = "ftl demo";
    exec = "/run/current-system/sw/bin/sleep infinity";
  };
}
