# invalid with cycle-b: a cycle of two
{ pkgs }:
{
  inputs = [ "cycle-b/x" ];
  files.x = { };
  script = "";
}
