# fleetl: the fleet from the admin's machine, inside the repository.
#
#   fleetl secrets sync [--check|--rekey]
#                                       .sops.yaml from the layout; re-key the stores
#                                       whose recipients are not the rules' (--rekey: all)
#   fleetl secrets render               .sops.yaml for the `fleet.sops` JSON on stdin
#   fleetl secrets edit <store>         sops on a store (creates it)
#   fleetl host init <name> [--system <s>] [--age-key]
#                                       new host folder, its generators run
#   fleetl host generate <name> [--force] [<generator>...]
#                                       run the host's generators whose files are missing
#                                       (their inputs first, fleet generators included)
#   fleetl host install <name> <target> [--disk-key] [-- <nixos-anywhere args>]
#                                       install a host with its identity in place
#   fleetl host exec <name>|all [--user <u>] [--] <command...>
#                                       run a command on a host (all: every host that
#                                       is not ignored), pinned to its ssh.pub
#   fleetl host show <name>             a host: services, users, layers, keys, stores
#   fleetl service show <name>          a service: hosts, roles, layers, data, store
#   fleetl state list <host>            the host's state entries, and copies kept aside
#   fleetl state size|stop|start <host> <entry>...
#   fleetl state snapshots <host> [<entry>]
#                                       their backups
#   fleetl state backup <host> --all|<entry>...
#                                       back them up now
#   fleetl state restore <host> <entry> [--snapshot <id>] [--from-host <h>] [--no-start]
#                                       put an entry back as a backup has it (restored
#                                       beside it, then swapped in; the current content
#                                       kept aside)
#   fleetl state rollback <host> <entry> [<aside>]
#   fleetl state discard <host> <aside> swap a copy kept aside back in; destroy one
#   fleetl fleet generate [--force] [<generator>...]
#                                       run the fleet's generators whose files are missing
#   fleetl fleet show                   the fleet: hosts, services, users, keys, stores
#   fleetl user init <name> [--admin] [--ssh-key <file>] [--pgp <fpr>] [--age <recipient>]
#                                       new user folder from the agent's keys
#   fleetl user show <name>
#
# Everything is read through the flake (`nix eval .#fleet`), so new files must
# be known to git (`git add`, intent-to-add is enough); init does that itself.

usage() {
  sed -n '/^# fleetl:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

die() {
  echo "fleetl: $*" >&2
  exit 1
}

# Scratch space for private keys and plaintext, 0700, gone on any exit (a
# `die` and errexit included, which a RETURN trap would miss).
tmp="$(mktemp -d)"
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT

# Everything but `secrets render` works on the repository.
in_repo() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not in a git repository"
  cd "$root"
}

fleet_json() { # <attr path below fleet>
  nix eval --json ".#fleet.$1"
}

# --- secrets -------------------------------------------------------------------

# .sops.yaml for a `fleet.sops` JSON document on stdin.  SSH host keys become
# age recipients here; nothing else is derived, so the result is a function of
# the layout and stable across runs.
secrets_render() {
  local input map key
  input="$(cat)"
  map='{}'
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    map="$(jq -c --arg k "$key" --arg v "$(printf '%s\n' "$key" | ssh-to-age)" '. + {($k): $v}' <<<"$map")"
  done < <(jq -r '[.stores[].recipients.ssh[]] | unique[]' <<<"$input")

  echo "# Written by \`fleetl secrets sync\` from the fleet's layout (see fleet.sops)."
  echo "# Who may read a store follows from users/, nixos/hosts/ and nixos/services/;"
  echo "# edit those, not this file."
  jq --argjson map "$map" '
    def regex: "^" + gsub("\\."; "\\.") + "$";
    {
      creation_rules: ([
        .stores[] | {
          path_regex: (.path | regex),
          key_groups: [
            ({ pgp: .recipients.pgp, age: (.recipients.age + [.recipients.ssh[] | $map[.]] | unique) }
             | with_entries(select(.value != [])))
          ]
        }
      ] + (.extraRules | map((if has("path_regex") then { path_regex } else { } end) + .)))
    }' <<<"$input" | yq -P
}

# The recipients a store should have, from the rules; and the ones it has,
# which sops keeps in the clear.  Both as sorted lists of age recipients and
# pgp fingerprints.
rule_recipients() { # <store path>
  local n i regex
  n="$(yq '.creation_rules | length' .sops.yaml)"
  for ((i = 0; i < n; i++)); do
    regex="$(yq ".creation_rules[$i].path_regex" .sops.yaml)"
    if [[ $1 =~ $regex ]]; then
      yq ".creation_rules[$i].key_groups[] | (.age[]?, .pgp[]?)" .sops.yaml | sort -u
      return 0
    fi
  done
  return 1
}

store_recipients() { # <store path>
  yq '.sops.age[]?.recipient, .sops.pgp[]?.fp' "$1" | sort -u
}

# .sops.yaml from the layout, and every existing store re-keyed to it where
# its recipients differ (which needs the admin's key).  --check reports both
# without changing anything; --rekey re-keys every store.
secrets_sync() {
  in_repo
  local check=0 force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) check=1 ;;
      --rekey) force=1 ;;
      *) usage ;;
    esac
    shift
  done

  # 1. the rules
  fleet_json sops | secrets_render >"$tmp/sops.yaml"
  if [ -f .sops.yaml ] && cmp -s "$tmp/sops.yaml" .sops.yaml; then
    echo ".sops.yaml is up to date"
  elif [ "$check" = 1 ]; then
    [ -f .sops.yaml ] && diff -u .sops.yaml "$tmp/sops.yaml" || true
    die ".sops.yaml is stale; run fleetl secrets sync"
  else
    [ -f .sops.yaml ] && diff -u .sops.yaml "$tmp/sops.yaml" || true
    install -m 644 "$tmp/sops.yaml" .sops.yaml
    echo "wrote .sops.yaml"
  fi

  # 2. the stores: those whose recipients are not the rules'
  local store stale=() failed=()
  while IFS= read -r store; do
    [ -f "$store" ] || continue
    if [ "$force" = 1 ] || ! cmp -s <(rule_recipients "$store") <(store_recipients "$store"); then
      stale+=("$store")
    fi
  done < <(fleet_json sops | jq -r '.stores[].path')
  if [ "${#stale[@]}" = 0 ]; then
    echo "every store has the recipients of its rule"
    return 0
  fi
  if [ "$check" = 1 ]; then
    printf '%s: recipients differ from its rule\n' "${stale[@]}"
    die "run fleetl secrets sync"
  fi
  for store in "${stale[@]}"; do
    echo "re-keying $store"
    sops updatekeys -y "$store" || failed+=("$store")
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    die "could not re-key: ${failed[*]}"
  fi
}

secrets_edit() {
  in_repo
  local store="${1:?usage: fleetl secrets edit <store>}"
  fleet_json sops | jq -e --arg s "$store" '.stores[] | select(.path == $s)' >/dev/null ||
    die "$store is not a store of this fleet (see fleetl secrets sync)"
  exec sops "$store"
}

# --- show ----------------------------------------------------------------------

show() { # <kind: hosts|services|users> <name>
  in_repo
  local kind="$1" name="$2" json
  json="$(fleet_json "$kind" | jq -e --arg n "$name" '.[$n]')" ||
    die "no $kind entry '$name'"
  jq -r --arg kind "$kind" '
    def list: if . == [] then "-" else join(" ") end;
    "\(.name) (\($kind | rtrimstr("s")))",
    (to_entries[] | select(.key != "name") |
      if (.value | type) == "array" then "  \(.key): \(.value | list)"
      elif (.value | type) == "object" then "  \(.key):", (.value | to_entries[] | "    \(.key): \(.value | tostring)")
      else "  \(.key): \(.value)" end)' <<<"$json"
  if [ "$kind" = services ]; then
    echo "  state:"
    local h
    for h in $(jq -r '.hosts[]' <<<"$json"); do
      nix eval --json ".#nixosConfigurations.$h.config.fleet.state" 2>/dev/null |
        jq -r --arg n "$name" --arg h "$h" '
          to_entries[] | select(.value.service == $n) |
          "    \($h): \(.key) \(.value.path) (\(.value.location), \(.value.kind))"'
    done
  fi
  echo "  stores:"
  fleet_json sops | jq -r --arg n "$name" --arg kind "$kind" '
    .stores[] | select(
      ($kind == "hosts" and (.kind == "host" or .kind == "identity") and .owner == $n) or
      ($kind == "services" and .kind == "service" and .owner == $n) or
      ($kind == "users" and .kind == "user" and .owner == $n)) |
    "    \(.path)"'
}

# --- host ----------------------------------------------------------------------

host_init() {
  in_repo
  local name="${1:?usage: fleetl host init <name> [--system <s>] [--age-key]}" system=x86_64-linux agekey=0
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --system) system="${2:?--system needs a value}"; shift 2 ;;
      --age-key) agekey=1; shift ;;
      *) usage ;;
    esac
  done
  local dir="nixos/hosts/$name"
  [ -e "$dir" ] && die "$dir exists"

  mkdir -p "$dir"
  {
    echo "# ftl host metadata (not a NixOS module); everything below \`importance\` is"
    echo "# shared with every host through \`fleet.hosts\`."
    echo "{"
    echo "  system = \"$system\";"
    echo "  importance = \"required\";"
    if [ "$agekey" = 1 ]; then
      echo
      echo "  # the host keys, and a dedicated age key for its secrets instead of the"
      echo "  # SSH host key"
      echo "  generators = ["
      echo "    \"host-keys\""
      echo "    \"age-key\""
      echo "  ];"
    fi
    echo "}"
  } >"$dir/host.nix"
  git add -N "$dir"

  host_generate "$name"
  echo "created $dir; next: its modules, then fleetl secrets edit $dir/secrets.yaml"
}

# --- generators ----------------------------------------------------------------

# Where a scope keeps its files: a host's next to its host.nix, the fleet's
# in nixos/.  Secrets go to the scope's secrets.yaml (as <generator>/<file>)
# or identity.yaml (as <file>).
scope_dir() { # <scope>
  if [ "$1" = fleet ]; then echo nixos; else echo "nixos/hosts/$host"; fi
}

# Is a secret of a generator in a store already?  sops leaves the keys of a
# store in the clear, only the values are encrypted.
has_secret() { # <store file> <yq path>
  [ -f "$1" ] && yq -e "$2" "$1" >/dev/null 2>&1
}

has_file() { # <dir> <generator> <file> <secret> <store>
  if [ "$4" = true ]; then
    if [ "$5" = identity ]; then
      has_secret "$1/identity.yaml" ".[\"$3\"]"
    else
      has_secret "$1/secrets.yaml" ".[\"$2\"][\"$3\"]"
    fi
  else
    [ -e "$1/$3" ]
  fi
}

# A file of a generator for an input of another: generated this run, else
# from the repository (a public file as is, a secret decrypted from its store,
# which needs the admin's key).
materialize() { # <generator> <file> <destination>
  local spec scope sdir secret st
  spec="$(jq --arg g "$1" '.[$g]' <<<"$gens")"
  scope="$(jq -r '.scope' <<<"$spec")"
  sdir="$(scope_dir "$scope")"
  secret="$(jq -r --arg f "$2" '.files[$f].secret // false' <<<"$spec")"
  st="$(jq -r --arg f "$2" '.files[$f].store // "secrets"' <<<"$spec")"
  install -d -m 700 "$(dirname "$3")"
  if [ -e "$tmp/$scope/$1/$2" ]; then
    cp "$tmp/$scope/$1/$2" "$3"
  elif [ "$secret" != true ]; then
    cp "$sdir/$2" "$3"
  elif [ "$st" = identity ]; then
    (umask 077; sops decrypt --extract "[\"$2\"]" "$sdir/identity.yaml" >"$3") ||
      die "could not read $1/$2 from $sdir/identity.yaml (needs your key)"
  else
    (umask 077; sops decrypt --extract "[\"$1\"][\"$2\"]" "$sdir/secrets.yaml" >"$3") ||
      die "could not read $1/$2 from $sdir/secrets.yaml (needs your key)"
  fi
}

# Run a generator for the host (`$host`), or for the fleet when it is
# fleet-scoped, unless its files are all there; its inputs come first, made
# now if missing.  Public files land in the scope's directory right away; the
# secrets wait in $tmp/<scope>/<generator> for write_stores.  `seen` remembers
# what was looked at, `ran` what ran (as <scope>/<generator>), `written` the
# public files.
ensure() { # <generator> <force>
  local gen="$1" force="$2" spec scope sdir label f secret st
  spec="$(jq -e --arg g "$gen" '.[$g]' <<<"$gens")" || die "no generator '$gen'"
  scope="$(jq -r '.scope' <<<"$spec")"
  if [ "$scope" = fleet ]; then
    label="the fleet"
  else
    [ -n "$host" ] || die "'$gen' is a host's generator: fleetl host generate <host> $gen"
    label="$host"
  fi
  sdir="$(scope_dir "$scope")"
  [ -d "$sdir" ] || die "no $sdir"
  case " ${seen[*]:-} " in *" $scope/$gen "*) return 0 ;; esac
  seen+=("$scope/$gen")

  if [ "$force" = 0 ]; then
    local missing=0
    while IFS=$'\t' read -r f secret st; do
      has_file "$sdir" "$gen" "$f" "$secret" "$st" || missing=1
    done < <(jq -r '.files | to_entries[] | [.key, (.value.secret // false | tostring), (.value.store // "secrets")] | @tsv' <<<"$spec")
    if [ "$missing" = 0 ]; then
      echo "$gen: $label has its files"
      return 0
    fi
  fi

  local input
  mkdir -p "$tmp/in/$gen"
  while IFS= read -r input; do
    [ -n "$input" ] || continue
    ensure "${input%%/*}" 0
    materialize "${input%%/*}" "${input#*/}" "$tmp/in/$gen/$input"
  done < <(jq -r '.inputs[]' <<<"$spec")

  echo "$gen: generating for $label"
  mkdir -p "$tmp/$scope/$gen"
  HOST="${host:-fleet}" nix run ".#generate-$gen" -- "$tmp/$scope/$gen" "$tmp/in/$gen"
  while IFS= read -r f; do
    install -m 644 "$tmp/$scope/$gen/$f" "$sdir/$f"
    written+=("$sdir/$f")
  done < <(jq -r '.files | to_entries[] | select(.value.secret != true) | .key' <<<"$spec")
  ran+=("$scope/$gen")
}

# The secrets of what ran for a scope, into its stores: all at once into a
# new store (no key needed), one by one into an existing one (the admin's).
write_stores() { # <scope>
  local scope="$1" sdir store path doc gen spec f
  sdir="$(scope_dir "$scope")"
  for store in secrets identity; do
    path="$sdir/$store.yaml"
    doc="$tmp/$scope-$store.yaml"
    : >"$doc"
    local -a keys=() files=()
    for gen in "${ran[@]}"; do
      [ "${gen%%/*}" = "$scope" ] || continue
      gen="${gen#*/}"
      spec="$(jq --arg g "$gen" '.[$g]' <<<"$gens")"
      while IFS= read -r f; do
        if [ "$store" = identity ]; then
          F="$f" V="$(cat "$tmp/$scope/$gen/$f")" yq -i '.[strenv(F)] = strenv(V)' "$doc"
          keys+=("[\"$f\"]")
        else
          G="$gen" F="$f" V="$(cat "$tmp/$scope/$gen/$f")" yq -i '.[strenv(G)][strenv(F)] = strenv(V)' "$doc"
          keys+=("[\"$gen\"][\"$f\"]")
        fi
        files+=("$tmp/$scope/$gen/$f")
      done < <(jq -r --arg s "$store" \
        '.files | to_entries[] | select(.value.secret == true and (.value.store // "secrets") == $s) | .key' <<<"$spec")
    done
    [ "${#keys[@]}" = 0 ] && continue
    if [ -f "$path" ]; then
      echo "$path: adding ${#keys[@]} secret(s) (needs your key)"
      local i
      for i in "${!keys[@]}"; do
        sops set "$path" "${keys[$i]}" "$(jq -Rs . <"${files[$i]}")" ||
          die "could not add ${keys[$i]} to $path"
      done
    else
      echo "$path: written"
      sops --encrypt --filename-override "$path" --output "$path" "$doc"
      git add -N "$path"
    fi
  done
}

# The generators named, with their inputs, and the stores after them
# (globals: host, gens, force).
generate() { # <generator>...
  local -a seen=() ran=() written=()
  local gen
  for gen in "$@"; do
    ensure "$gen" "$force"
  done
  [ "${#ran[@]}" = 0 ] && return 0

  # the public files may have made a host a recipient (of its own store, of
  # its services', of the fleet's); the rules follow here, the re-keying of
  # existing stores is `fleetl secrets sync`, which needs the admin's key
  git add -N "${written[@]}"
  fleet_json sops | secrets_render >"$tmp/sops.yaml"
  install -m 644 "$tmp/sops.yaml" .sops.yaml

  write_stores fleet
  [ -n "$host" ] && write_stores host
  return 0
}

# Run the host's generators whose files are missing (or the ones named;
# --force runs them again), their inputs first.
host_generate() {
  in_repo
  local host="${1:?usage: fleetl host generate <name> [--force] [<generator>...]}" force=0
  shift
  local -a wanted=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      -*) usage ;;
      *) wanted+=("$1"); shift ;;
    esac
  done
  [ -d "nixos/hosts/$host" ] || die "no nixos/hosts/$host"
  local gens
  gens="$(fleet_json generators)"
  if [ "${#wanted[@]}" = 0 ]; then
    mapfile -t wanted < <(fleet_json "hosts.$host" | jq -r '.generators[]')
  fi
  local gen
  for gen in "${wanted[@]}"; do
    if jq -e --arg g "$gen" '.[$g].scope == "fleet"' <<<"$gens" >/dev/null; then
      die "'$gen' is the fleet's generator: fleetl fleet generate $gen"
    fi
  done
  generate "${wanted[@]}"
}

# The fleet's generators (scope = "fleet") the same way.
fleet_generate() {
  in_repo
  local host="" force=0
  local -a wanted=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      -*) usage ;;
      *) wanted+=("$1"); shift ;;
    esac
  done
  local gens
  gens="$(fleet_json generators)"
  if [ "${#wanted[@]}" = 0 ]; then
    mapfile -t wanted < <(jq -r 'to_entries[] | select(.value.scope == "fleet") | .key' <<<"$gens")
  fi
  if [ "${#wanted[@]}" = 0 ]; then
    echo "no fleet generators (scope = \"fleet\" in nixos/generators/)"
    return 0
  fi
  generate "${wanted[@]}"
}

fleet_show() {
  in_repo
  local hosts services users keys gens
  hosts="$(fleet_json hosts | jq -r 'keys | join(" ")')"
  services="$(fleet_json services | jq -r 'keys | join(" ")')"
  users="$(fleet_json users | jq -r 'keys | join(" ")')"
  keys="$(fleet_json keys | jq -r 'to_entries[] | "    \(.key): \(.value)"')"
  gens="$(fleet_json generators | jq -r '[to_entries[] | select(.value.scope == "fleet") | .key] | join(" ")')"
  echo "fleet"
  echo "  hosts: ${hosts:--}"
  echo "  services: ${services:--}"
  echo "  users: ${users:--}"
  echo "  keys:"
  [ -n "$keys" ] && echo "$keys"
  echo "  generators: ${gens:--}"
  echo "  stores:"
  fleet_json sops | jq -r '.stores[] | select(.kind == "fleet" or .kind == "fleet-identity") | "    \(.path)"'
}

host_install() {
  in_repo
  local name="${1:?usage: fleetl host install <name> <target> [--disk-key] [-- <nixos-anywhere args>]}"
  local target="${2:?usage: fleetl host install <name> <target> [--disk-key] [-- <nixos-anywhere args>]}"
  shift 2
  local diskkey=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --disk-key) diskkey=1; shift ;;
      --) shift; break ;;
      *) usage ;;
    esac
  done

  local identity="nixos/hosts/$name/identity.yaml"
  [ -f "$identity" ] || die "no $identity; fleetl host init $name first"


  local extra="$tmp/extra" keys
  install -d -m 755 "$extra/etc/ssh"
  keys="$(sops decrypt --output-type json "$identity")"

  extract() { # <key> <file>
    (umask 077; jq -r --arg k "$1" '.[$k]' <<<"$keys" >"$2")
  }
  extract ssh_host_ed25519_key "$extra/etc/ssh/ssh_host_ed25519_key"
  ssh-keygen -y -f "$extra/etc/ssh/ssh_host_ed25519_key" >"$extra/etc/ssh/ssh_host_ed25519_key.pub"
  if jq -e 'has("initrd_ssh_host_ed25519_key")' <<<"$keys" >/dev/null; then
    install -d -m 700 "$extra/etc/secrets/initrd"
    extract initrd_ssh_host_ed25519_key "$extra/etc/secrets/initrd/ssh_host_ed25519_key"
  fi
  if jq -e 'has("age_key")' <<<"$keys" >/dev/null; then
    install -d -m 700 "$extra/var/lib/sops-nix"
    extract age_key "$extra/var/lib/sops-nix/key.txt"
  fi
  unset keys

  local -a args=(--flake ".#$name" --target-host "root@$target" --extra-files "$extra")
  if [ "$diskkey" = 1 ]; then
    local pass again
    read -rsp "Disk passphrase for $name: " pass; echo
    read -rsp "Repeat: " again; echo
    if [ -z "$pass" ] || [ "$pass" != "$again" ]; then
      die "passphrases empty or different"
    fi
    (umask 077; printf '%s' "$pass" >"$tmp/disk.key")
    unset pass again
    args+=(--disk-encryption-keys /tmp/disk.key "$tmp/disk.key")
  fi

  nixos-anywhere "${args[@]}" "$@"
}

# ssh_to <host> [<user>]: the ssh command line for a host, in ${ssh_cmd[@]}.
# The address and the login are those of the deploy output when the
# repository has one (mkDeploy: `address`, `sshUser`), else the host's fqdn or
# name and root; the connection is pinned to the host's ssh.pub like a
# deploy.  FLEETL_SSH replaces the ssh program (tests).
hosts_json=""
ssh_cmd=()
ssh_user=""
ssh_to() {
  local h="$1" user="${2:-}" address key
  [ -n "$hosts_json" ] || hosts_json="$(fleet_json hosts)"
  jq -e --arg h "$h" 'has($h)' <<<"$hosts_json" >/dev/null || die "no host '$h'"
  [ -n "$user" ] || user="$(nix eval --raw .#deploy.sshUser 2>/dev/null || echo root)"
  address="$(nix eval --raw ".#deploy.nodes.\"$h\".hostname" 2>/dev/null || jq -r --arg h "$h" '.[$h].fqdn // $h' <<<"$hosts_json")"
  key="$(jq -r --arg h "$h" '.[$h].keys.ssh // empty' <<<"$hosts_json")"
  ssh_cmd=("${FLEETL_SSH:-ssh}")
  if [ -n "$key" ]; then
    echo "$h $key" >"$tmp/known_hosts.$h"
    ssh_cmd+=(-o "HostKeyAlias=$h" -o "UserKnownHostsFile=$tmp/known_hosts.$h" -o StrictHostKeyChecking=yes)
  else
    echo "fleetl: $h has no ssh.pub, trusting your known_hosts" >&2
  fi
  ssh_user="$user"
  ssh_cmd+=("$user@$address")
}

# as_root <host> <command...>: the command as root on the host, quoted (by
# bash's printf %q, for a bash or POSIX login shell) for the remote shell;
# through sudo unless the login is root.  sudo asks the agent (pam_rssh), so
# the agent is forwarded for the time of the command: root on that host can
# use it meanwhile, as with any forwarded agent (ssh-add -c makes each use
# ask).
as_root() {
  local h="$1"
  shift
  ssh_to "$h"
  local -a cmd=("$@")
  if [ "$ssh_user" != root ]; then
    cmd=(sudo "${cmd[@]}")
    ssh_cmd=("${ssh_cmd[0]}" -A "${ssh_cmd[@]:1}")
  fi
  "${ssh_cmd[@]}" -- "$(printf '%q ' "${cmd[@]}")" || {
    local rc=$?
    if [ "$ssh_user" != root ] && [ "$rc" = 1 ]; then
      echo "fleetl: if sudo refused on $h: it authenticates with your agent (pam_rssh); is it forwarded and holding your key (ssh-add -L)?" >&2
    fi
    return "$rc"
  }
}

# A command on one host, or on every host that is not ignored, one after the
# other (see ssh_to for how a host is reached).
host_exec() {
  in_repo
  local name="${1:?usage: fleetl host exec <name>|all [--user <u>] [--] <command...>}"
  shift
  local user=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --user) user="${2:?--user needs a name}"; shift 2 ;;
      --) shift; break ;;
      -*) usage ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || die "host exec: no command given"

  hosts_json="$(fleet_json hosts)"
  [ -n "$user" ] || user="$(nix eval --raw .#deploy.sshUser 2>/dev/null || echo root)"
  local -a names
  if [ "$name" = all ]; then
    mapfile -t names < <(jq -r 'to_entries[] | select(.value.importance != "ignored") | .key' <<<"$hosts_json")
  else
    jq -e --arg h "$name" 'has($h)' <<<"$hosts_json" >/dev/null || die "no host '$name'"
    names=("$name")
  fi

  local h status=0
  for h in "${names[@]}"; do
    ssh_to "$h" "$user"
    if [ "$name" = all ]; then
      echo "== $h (${ssh_cmd[-1]})" >&2
    fi
    "${ssh_cmd[@]}" -- "$@" || {
      status=$?
      [ "$name" = all ] || exit "$status"
      echo "fleetl: $h: exit $status" >&2
    }
  done
  exit "$status"
}

# --- state ---------------------------------------------------------------------

# fleet-state on a host, as root (see `fleet-state help` there for the
# details).
state_cmd() {
  in_repo
  local sub="$1" h="${2:?usage: fleetl state $1 <host> ...}"
  shift 2
  case "$sub" in
    restore | rollback) [ $# -gt 0 ] || die "usage: fleetl state $sub <host> <entry> ..." ;;
    discard) [ $# = 1 ] || die "usage: fleetl state discard <host> <aside>" ;;
  esac
  as_root "$h" fleet-state "$sub" "$@"
}

# --- user ----------------------------------------------------------------------

user_init() {
  in_repo
  local name="${1:?usage: fleetl user init <name> [--admin] [--ssh-key <file>] [--pgp <fpr>] [--age <recipient>]}"
  shift
  local admin=false sshkey="" pgp="" age=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --admin) admin=true; shift ;;
      --ssh-key) sshkey="${2:?--ssh-key needs a file}"; shift 2 ;;
      --pgp) pgp="${2:?--pgp needs a fingerprint}"; shift 2 ;;
      --age) age="${2:?--age needs a recipient}"; shift 2 ;;
      *) usage ;;
    esac
  done
  local dir="users/$name"
  [ -e "$dir" ] && die "$dir exists"
  mkdir -p "$dir"

  cat >"$dir/user.nix" <<EOF
# ftl user metadata (not a module): where $name has an account, see the README.
{
  admin = $admin;
}
EOF

  if [ -n "$sshkey" ]; then
    awk '{ print $1, $2 }' "$sshkey" >"$dir/ssh.pub"
  elif ssh-add -L 2>/dev/null | awk '{ print $1, $2 }' >"$dir/ssh.pub" && [ -s "$dir/ssh.pub" ]; then
    echo "ssh.pub: the keys of the running ssh-agent"
  else
    rm -f "$dir/ssh.pub"
    echo "no --ssh-key and no ssh-agent: add $dir/ssh.pub yourself" >&2
  fi

  if [ -z "$pgp" ] && [ -z "$age" ]; then
    # the primary fingerprint of the first secret key gpg knows (a card counts)
    pgp="$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
    [ -n "$pgp" ] && echo "sops.pgp: $pgp (from gpg)"
  fi
  [ -n "$pgp" ] && echo "$pgp" >"$dir/sops.pgp"
  [ -n "$age" ] && echo "$age" >"$dir/sops.age"
  if [ -z "$pgp" ] && [ -z "$age" ]; then
    echo "no sops key: $name can read no store until $dir/sops.pgp or sops.age exists" >&2
  fi

  git add -N "$dir"
  echo "created $dir; next: fleetl secrets sync"
}

# --- dispatch ------------------------------------------------------------------

case "${1:-}" in
  secrets)
    case "${2:-}" in
      sync) shift 2; secrets_sync "$@" ;;
      render) secrets_render ;;
      edit) secrets_edit "${3:-}" ;;
      *) usage ;;
    esac
    ;;
  host)
    case "${2:-}" in
      init) shift 2; host_init "$@" ;;
      generate) shift 2; host_generate "$@" ;;
      install) shift 2; host_install "$@" ;;
      exec) shift 2; host_exec "$@" ;;
      show) show hosts "${3:?usage: fleetl host show <name>}" ;;
      *) usage ;;
    esac
    ;;
  fleet)
    case "${2:-}" in
      generate) shift 2; fleet_generate "$@" ;;
      show) fleet_show ;;
      *) usage ;;
    esac
    ;;
  state)
    case "${2:-}" in
      list | size | stop | start | snapshots | backup | restore | rollback | discard) state_cmd "${@:2}" ;;
      *) usage ;;
    esac
    ;;
  service)
    case "${2:-}" in
      show) show services "${3:?usage: fleetl service show <name>}" ;;
      *) usage ;;
    esac
    ;;
  user)
    case "${2:-}" in
      init) shift 2; user_init "$@" ;;
      show) show users "${3:?usage: fleetl user show <name>}" ;;
      *) usage ;;
    esac
    ;;
  -h | --help | help) usage 0 ;;
  *) usage ;;
esac
