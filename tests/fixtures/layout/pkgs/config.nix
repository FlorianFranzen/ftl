{ lib }:
{
  allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "unfree-ftl" ];
}
