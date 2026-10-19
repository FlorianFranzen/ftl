# valid: reads the host keys
{ pkgs }:
{
  inputs = [ "host-keys/ssh.pub" ];
  files.x = { };
  script = "";
}
