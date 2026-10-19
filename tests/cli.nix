# fleetl: the fixture's .sops.yaml is what `secrets render` makes of its
# layout (SSH host keys converted with ssh-to-age), as the fleet-sops check
# verifies; and `host exec` reaches a host pinned to its ssh.pub.  The script
# runs on stubs here: `nix eval` answers from the evaluated fleet, `git`
# names the fixture, `ssh` echoes what it would run.
{
  pkgs,
  ftl,
  fixture,
  inputs,
  ...
}:
let
  f = ftl.lib.mkFlake {
    src = fixture;
    inherit inputs;
    name = "cli";
    home = {
      bases = {
        terminal = [ "terminal" ];
        desktop = [
          "terminal"
          "desktop"
        ];
      };
      username = "alice";
    };
    sops.extraRules = [
      {
        path_regex = "^tests/.*\\.yaml$";
        key_groups = [ { age = [ "age1test" ]; } ];
      }
    ];
  };

  hostsJson = pkgs.writeText "hosts.json" (builtins.toJSON f.fleet.hosts);

  stubs = pkgs.runCommand "fleetl-stubs" { } ''
    mkdir -p $out/bin
    cat > $out/bin/nix <<'STUB'
    #!/bin/sh
    case "$*" in
      *".#fleet.hosts") cat ${hostsJson} ;;
      *".#deploy.sshUser") printf admin ;;
      *".#deploy.nodes.\"alpha\".hostname") printf 10.0.0.1 ;;
      *) echo "stub nix: no $*" >&2; exit 1 ;;
    esac
    STUB
    cat > $out/bin/git <<'STUB'
    #!/bin/sh
    [ "$1 $2" = "rev-parse --show-toplevel" ] && { echo "$PWD"; exit 0; }
    echo "stub git: no $*" >&2; exit 1
    STUB
    cat > $out/bin/ssh <<'STUB'
    #!/bin/sh
    echo "ssh $*"
    STUB
    chmod +x $out/bin/*
    patchShebangs $out/bin
  '';
in
pkgs.runCommand "cli"
  {
    nativeBuildInputs = [
      stubs
      pkgs.jq
    ];
    sopsCheck = f.checks.x86_64-linux.fleet-sops;
  }
  ''
    fleetl() { bash -o errexit -o nounset -o pipefail ${../scripts/fleetl.sh} "$@"; }
    cd $TMPDIR

    # one host: the deploy output's address and login, pinned to the host key
    got="$(fleetl host exec alpha -- uptime -p)"
    echo "$got"
    case "$got" in
      "ssh -o HostKeyAlias=alpha -o UserKnownHostsFile="*"/known_hosts.alpha -o StrictHostKeyChecking=yes admin@10.0.0.1 -- uptime -p") ;;
      *) echo "host exec alpha: unexpected command"; exit 1 ;;
    esac
    known="$(echo "$got" | sed 's/.*UserKnownHostsFile=\([^ ]*\).*/\1/')"
    [ ! -e "$known" ] || { echo "scratch known_hosts left behind"; exit 1; }

    # --user wins; a host without ssh.pub is not pinned; all = every host not ignored
    got="$(fleetl host exec all --user root -- true 2>/dev/null)"
    echo "$got"
    [ "$(echo "$got" | wc -l)" = ${toString (builtins.length (builtins.attrNames (pkgs.lib.filterAttrs (_: h: h.importance != "ignored") f.fleet.hosts)))} ] || { echo "host exec all: wrong host count"; exit 1; }
    echo "$got" | grep -q '^ssh root@beta -- true$' || { echo "beta should not be pinned"; exit 1; }

    ! fleetl host exec nosuch -- true 2>/dev/null || { echo "unknown host accepted"; exit 1; }
    ! fleetl host exec alpha 2>/dev/null || { echo "missing command accepted"; exit 1; }

    touch $out
  ''
