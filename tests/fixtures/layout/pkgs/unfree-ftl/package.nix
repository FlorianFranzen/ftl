{ lib, runCommand }:
runCommand "unfree-ftl" { meta.license = lib.licenses.unfree; } "mkdir -p $out/share/unfree-ftl"
