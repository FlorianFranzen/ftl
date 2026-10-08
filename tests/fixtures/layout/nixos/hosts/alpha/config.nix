{
  pkgs,
  profiles,
  homes,
  static,
  ...
}:
{
  imports = [
    profiles.base.common
    profiles.extra.only
  ];

  # local overlay package and an unfree package allowed by pkgs/config.nix
  environment.systemPackages = [
    pkgs.hello-ftl
    pkgs.unfree-ftl
  ];

  # static files are only used where the config says so
  environment.etc."marker".source = static.marker;

  home-manager.users.alice = homes.desktop-dark;
}
