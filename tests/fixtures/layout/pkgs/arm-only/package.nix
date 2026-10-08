{ runCommand }:
runCommand "arm-only" { meta.platforms = [ "aarch64-linux" ]; } "mkdir -p $out/share/arm-only"
