{ pkgs, ... }:
{
  boot.loader.grub.device = "nodev";
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  environment.systemPackages = [ pkgs.hello-example ];
  system.stateVersion = "26.05";
}
