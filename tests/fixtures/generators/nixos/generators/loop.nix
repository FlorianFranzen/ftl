# invalid: an input of itself
{ pkgs }:
{
  inputs = [ "loop/x" ];
  files.x = { };
  script = "";
}
