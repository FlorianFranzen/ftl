# invalid: an input the generator does not make
{ pkgs }:
{
  inputs = [ "host-keys/nope" ];
  files.x = { };
  script = "";
}
