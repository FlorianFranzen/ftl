# invalid: an input of a generator that does not exist
{ pkgs }:
{
  inputs = [ "nope/x" ];
  files.x = { };
  script = "";
}
