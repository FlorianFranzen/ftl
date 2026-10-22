# fleetl on the fixture: `secrets render` makes its committed .sops.yaml (the
# fleet-sops check); `host exec` reaches a host pinned to its ssh.pub; `host
# generate` and `fleet generate` make what is missing, inputs first, and
# write the stores.  The script runs on stubs here: `nix eval` answers from
# the evaluated fleet, `nix run` starts the real generator programs, `git`
# names the copy of the fixture, `ssh` echoes what it would run.  The admin
# is a fresh age key (the fixture's stores belong to the fixture's alice).
{
  pkgs,
  ftl,
  fixture,
  inputs,
  ...
}:
let
  lib = pkgs.lib;
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

  alice = builtins.head (
    lib.splitString "\n" (builtins.readFile (fixture + "/users/alice/sops.age"))
  );

  # what `nix eval --json .#fleet.<attr>` answers
  fleetJson = pkgs.linkFarm "fleet-json" (
    lib.mapAttrsToList
      (name: value: {
        name = "${name}.json";
        path = pkgs.writeText "${name}.json" (builtins.toJSON value);
      })
      (
        {
          inherit (f.fleet)
            hosts
            services
            users
            keys
            generators
            sops
            ;
        }
        // lib.mapAttrs' (h: v: lib.nameValuePair "hosts.${h}" v) f.fleet.hosts
      )
  );

  programs = pkgs.symlinkJoin {
    name = "generators";
    paths = builtins.attrValues (
      lib.filterAttrs (n: _: lib.hasPrefix "generate-" n) f.packages.x86_64-linux
    );
  };

  stubs = pkgs.runCommand "fleetl-stubs" { } ''
    mkdir -p $out/bin
    cat > $out/bin/nix <<'STUB'
    #!/bin/sh
    case "$*" in
      # the admin is the fresh key; and once gamma has an ssh.pub (made in
      # this test) it is a recipient of its store and the fleet's, as a real
      # evaluation would see
      "eval --json .#fleet.sops")
        sed "s/${alice}/$ADMIN_AGE/g" ${fleetJson}/sops.json |
          if [ -f "$REPO/nixos/hosts/gamma/ssh.pub" ]; then
            ${pkgs.jq}/bin/jq --arg k "$(cut -d' ' -f1,2 "$REPO/nixos/hosts/gamma/ssh.pub")" \
              '(.stores[] | select(.path == "nixos/hosts/gamma/secrets.yaml" or .path == "nixos/secrets.yaml") | .recipients.ssh) |= (. + [$k] | unique)'
          else
            cat
          fi ;;
      "eval --json .#fleet."*) cat "${fleetJson}/''${3#.#fleet.}.json" ;;
      "eval --json .#deploy --apply "*)
        if [ -n "''${DEPLOY_BROKEN:-}" ]; then echo "error: deploy-rs: boom" >&2; exit 1; fi
        echo '{ "user": "admin", "hosts": { "alpha": "10.0.0.1" } }' ;;
      "run .#generate-"*) name="''${2#.#}"; shift 3; exec ${programs}/bin/"$name" "$@" ;;
      *) echo "stub nix: no $*" >&2; exit 1 ;;
    esac
    STUB
    cat > $out/bin/git <<'STUB'
    #!/bin/sh
    case "$1 $2" in
      "rev-parse --show-toplevel") echo "$REPO" ;;
      "add -N") ;;
      *) echo "stub git: no $*" >&2; exit 1 ;;
    esac
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
      pkgs.yq-go
      pkgs.sops
      pkgs.age
      pkgs.ssh-to-age
      pkgs.openssl
    ];
    sopsCheck = f.checks.x86_64-linux.fleet-sops;
  }
  ''
    fleetl() { bash -o errexit -o nounset -o pipefail ${../scripts/fleetl.sh} "$@"; }
    export REPO="$TMPDIR/repo"
    cp -r ${fixture} "$REPO"
    chmod -R u+w "$REPO"
    cd "$REPO"

    # --- host exec ---------------------------------------------------------
    # one host: the deploy output's address and login, pinned to the host key
    got="$(fleetl host exec alpha -- uptime -p)"
    echo "$got"
    case "$got" in
      "ssh -o BatchMode=yes -o ConnectTimeout=15 -o HostKeyAlias=alpha -o UserKnownHostsFile="*"/known_hosts.alpha -o StrictHostKeyChecking=yes admin@10.0.0.1 -- uptime -p") ;;
      *) echo "host exec alpha: unexpected command"; exit 1 ;;
    esac
    known="$(echo "$got" | sed 's/.*UserKnownHostsFile=\([^ ]*\).*/\1/')"
    [ ! -e "$known" ] || { echo "scratch known_hosts left behind"; exit 1; }

    # --user wins; a host without ssh.pub is not pinned; all = every host not ignored
    got="$(fleetl host exec all --user root -- true 2>/dev/null)"
    echo "$got"
    [ "$(echo "$got" | wc -l)" = ${
      toString (
        builtins.length (
          builtins.attrNames (lib.filterAttrs (_: h: h.importance != "ignored") f.fleet.hosts)
        )
      )
    } ] || { echo "host exec all: wrong host count"; exit 1; }
    echo "$got" | grep -q '^ssh -o BatchMode=yes -o ConnectTimeout=15 root@beta -- true$' || { echo "beta should not be pinned"; exit 1; }

    ! fleetl host exec nosuch -- true 2>/dev/null || { echo "unknown host accepted"; exit 1; }
    # a deploy output that fails to evaluate is an error, not root@<fqdn>
    ! DEPLOY_BROKEN=1 fleetl host exec alpha -- true 2>/dev/null || { echo "a broken deploy output fell back"; exit 1; }
    ! fleetl host exec alpha 2>/dev/null || { echo "missing command accepted"; exit 1; }

    # --- state ---------------------------------------------------------------
    # fleet-state as root: through sudo with the agent forwarded (pam_rssh)
    # unless the login is root, the arguments quoted for the remote shell
    got="$(fleetl state restore alpha mail --snapshot 'a b')"
    echo "$got"
    case "$got" in
      "ssh -A -o BatchMode=yes -o ConnectTimeout=15 -o HostKeyAlias=alpha "*" admin@10.0.0.1 -- sudo fleet-state restore mail --snapshot a\\ b ") ;;
      *) echo "state restore: unexpected command"; exit 1 ;;
    esac
    got="$(fleetl state list beta)"
    echo "$got"
    [ "$got" = "ssh -A -o BatchMode=yes -o ConnectTimeout=15 admin@beta -- sudo fleet-state list " ] || { echo "state list: unexpected command"; exit 1; }
    ! fleetl state restore alpha 2>/dev/null || { echo "restore without entry accepted"; exit 1; }
    got="$(fleetl state init beta)"
    [ "$got" = "ssh -A -o BatchMode=yes -o ConnectTimeout=15 admin@beta -- sudo fleet-state init " ] || { echo "state init: unexpected command"; exit 1; }
    ! fleetl state list nosuch 2>/dev/null || { echo "unknown host accepted"; exit 1; }

    # --- generators --------------------------------------------------------
    # the admin is a fresh key; the fixture's stores (the fixture's alice's)
    # are not touched: alpha's own store goes, gamma has none
    age-keygen -o "$TMPDIR/admin.key" 2>/dev/null
    export SOPS_AGE_KEY_FILE="$TMPDIR/admin.key"
    export ADMIN_AGE="$(age-keygen -y "$TMPDIR/admin.key")"
    rm nixos/hosts/alpha/secrets.yaml

    # the fleet's generators: ca, once, into nixos/ and nixos/identity.yaml
    fleetl fleet generate
    test -s nixos/ca.pub || { echo "fleet generate: no ca.pub"; exit 1; }
    yq -e '.["ca.key"]' nixos/identity.yaml >/dev/null || { echo "fleet generate: no ca.key in nixos/identity.yaml"; exit 1; }
    sops decrypt --extract '["ca.key"]' nixos/identity.yaml | grep -q 'PRIVATE KEY' || { echo "ca.key not readable by the admin"; exit 1; }
    again="$(fleetl fleet generate)"
    grep -q '^ca: the fleet has its files' <<<"$again" || { echo "fleet generate ran again"; exit 1; }
    grep -q '^fleet-ca: the fleet has its files' <<<"$again" || { echo "fleet generate ran fleet-ca again"; exit 1; }

    # a host generator with inputs: the ca (there) and the host keys (made
    # first), then the certificate, signed by the ca, into the host's stores
    fleetl host generate gamma cert | tee generate.log
    grep -q '^host-keys: generating for gamma' generate.log || { echo "host-keys not made first"; exit 1; }
    grep -q '^cert: generating for gamma' generate.log || { echo "cert not made"; exit 1; }
    openssl verify -CAfile nixos/ca.pub nixos/hosts/gamma/cert.pub
    grep -q "^# $(cut -d' ' -f1,2 nixos/hosts/gamma/ssh.pub)$" nixos/hosts/gamma/cert.pub || { echo "cert does not name the host key"; exit 1; }
    yq -e '.cert["cert.key"]' nixos/hosts/gamma/secrets.yaml >/dev/null || { echo "no cert.key in gamma's store"; exit 1; }
    yq -e '.["ssh_host_ed25519_key"]' nixos/hosts/gamma/identity.yaml >/dev/null || { echo "no host key in gamma's identity"; exit 1; }
    # the new host key made gamma a recipient of its store and of the fleet's
    gammaAge="$(ssh-to-age < nixos/hosts/gamma/ssh.pub)"
    yq -e ".sops.age[] | select(.recipient == \"$gammaAge\")" nixos/hosts/gamma/secrets.yaml >/dev/null || { echo "gamma cannot read its store"; exit 1; }
    grep -q "$gammaAge" .sops.yaml || { echo "gamma not in .sops.yaml"; exit 1; }

    # --force makes it again, reading the ca key back from the fleet's store
    # and adding to the existing host store
    fleetl host generate gamma --force cert | tee generate.log
    grep -q 'secrets.yaml: adding 1 secret' generate.log || { echo "forced cert not added to the store"; exit 1; }
    openssl verify -CAfile nixos/ca.pub nixos/hosts/gamma/cert.pub

    # a fleet generator is not a host's; an unknown generator fails
    ! fleetl host generate gamma ca 2>/dev/null || { echo "host generate ran a fleet generator"; exit 1; }
    ! fleetl host generate gamma nope 2>/dev/null || { echo "unknown generator accepted"; exit 1; }

    fleetl fleet show | tee show.log
    grep -q '^  generators: ca fleet-ca$' show.log || { echo "fleet show: generators"; exit 1; }
    grep -q '^    nixos/identity.yaml$' show.log || { echo "fleet show: stores"; exit 1; }

    # --- secrets move --------------------------------------------------------
    # a key both hosts hold alike goes to the service's store (made here), and
    # out of the hosts'; one they hold differently stays where it is
    printf 'shared:\n  a: |\n    same\nown:\n  x: beta\n' >plain.yaml
    sops --encrypt --filename-override nixos/hosts/beta/secrets.yaml --output nixos/hosts/beta/secrets.yaml plain.yaml
    sops set nixos/hosts/gamma/secrets.yaml '["shared"]["a"]' '"same\n"'
    sops set nixos/hosts/gamma/secrets.yaml '["own"]["x"]' '"gamma"'
    ! fleetl secrets move --to nixos/services/mesh/secrets.yaml \
      --from nixos/hosts/beta/secrets.yaml --from nixos/hosts/gamma/secrets.yaml own/x 2>/dev/null ||
      { echo "secrets move took a key that differs"; exit 1; }
    [ ! -e nixos/services/mesh/secrets.yaml ] || { echo "a refused move wrote the target"; exit 1; }
    fleetl secrets move --to nixos/services/mesh/secrets.yaml \
      --from nixos/hosts/beta/secrets.yaml --from nixos/hosts/gamma/secrets.yaml shared/a
    [ "$(sops decrypt --extract '["shared"]["a"]' nixos/services/mesh/secrets.yaml)" = same ] ||
      { echo "secrets move: the value did not arrive"; exit 1; }
    for h in beta gamma; do
      ! sops decrypt --extract '["shared"]["a"]' nixos/hosts/$h/secrets.yaml >/dev/null 2>&1 ||
        { echo "secrets move left the key in $h"; exit 1; }
      sops decrypt --extract '["own"]["x"]' nixos/hosts/$h/secrets.yaml | grep -qx $h ||
        { echo "secrets move touched another key in $h"; exit 1; }
    done
    # a key the target has already is not overwritten, and stays in the source
    sops set nixos/hosts/beta/secrets.yaml '["shared"]["a"]' '"other"'
    ! fleetl secrets move --to nixos/services/mesh/secrets.yaml --from nixos/hosts/beta/secrets.yaml shared/a 2>/dev/null ||
      { echo "secrets move overwrote a key in the target"; exit 1; }
    sops decrypt --extract '["shared"]["a"]' nixos/hosts/beta/secrets.yaml | grep -qx other ||
      { echo "a refused move took the key out of the source"; exit 1; }

    touch $out
  ''
