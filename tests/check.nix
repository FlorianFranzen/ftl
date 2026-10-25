# fleetl check: with one broken host.nix every output fails to evaluate, so
# fleetl check evaluates each metadata file on its own and names that one.
{
  pkgs,
  fixture,
  ...
}:
let
  fleetl = (import ../modules/scripts.nix { inherit pkgs; }).fleetl;
in
pkgs.runCommand "fleetl-check"
  {
    nativeBuildInputs = [
      fleetl
      pkgs.git
      pkgs.nix
    ];
  }
  ''
    export HOME=$TMPDIR NIX_STATE_DIR=$TMPDIR/nix NIX_LOG_DIR=$TMPDIR/nix/log
    cp -r ${fixture} repo && chmod -R u+w repo && cd repo
    git init -q && git add -A
    echo '{ system = "x86_64-linux" ' > nixos/hosts/beta/host.nix
    if fleetl check 2>err; then
      echo "fleetl check passed a broken host.nix"; exit 1
    fi
    cat err
    grep -q '^nixos/hosts/beta/host.nix:' err
    ! grep -q '^nixos/hosts/alpha/host.nix:' err
    grep -q 'do not evaluate on their own' err
    touch $out
  ''
