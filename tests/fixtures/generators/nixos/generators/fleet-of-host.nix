# invalid: a fleet generator reading a host's file
{ pkgs }:
{
  scope = "fleet";
  inputs = [ "host-keys/ssh.pub" ];
  files.x = { };
  script = "";
}
