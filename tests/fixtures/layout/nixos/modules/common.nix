# Imported into every host.
{ lib, ... }:
{
  options.fixture.common = lib.mkOption {
    type = lib.types.bool;
    default = true;
  };
  config = {
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "/dev/null";
      fsType = "ext4";
    };
    system.stateVersion = "26.05";
    fleet.layers.repo = "file:///dev/null";
  };
}
