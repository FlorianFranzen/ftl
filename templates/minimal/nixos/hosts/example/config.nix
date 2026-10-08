{ pkgs, static, ... }:
{
  boot.loader.grub.device = "nodev";
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  environment.systemPackages = [ pkgs.hello-example ];
  environment.etc."motd".source = static.motd;
  system.stateVersion = "26.05";
}
