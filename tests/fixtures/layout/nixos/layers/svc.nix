{
  kind = "services";
  packages = pkgs: [ pkgs.hello-ftl ];
  services.ftl-demo = {
    description = "ftl demo";
    exec = "/run/current-system/sw/bin/sleep infinity";
  };
}
