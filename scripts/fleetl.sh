# fleetl: the fleet from the admin's machine, inside the repository.
#
#   fleetl secrets sync [--check]       .sops.yaml from the layout, re-key the stores
#   fleetl secrets render               .sops.yaml for the `fleet.sops` JSON on stdin
#   fleetl secrets edit <store>         sops on a store (creates it)
#   fleetl host init <name> [--system <s>] [--age-key]
#                                       new host folder, its generators run
#   fleetl host generate <name> [--force] [<generator>...]
#                                       run the host's generators whose files are missing
#   fleetl host install <name> <target> [--disk-key] [-- <nixos-anywhere args>]
#                                       install a host with its identity in place
#   fleetl host show <name>             a host: services, users, layers, keys, stores
#   fleetl service show <name>          a service: hosts, roles, layers, data, store
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

secrets_sync() {
  in_repo
  local check=0 tmp
  case "${1:-}" in
    --check) check=1 ;;
    "") ;;
    *) usage ;;
  esac

  tmp="$(mktemp)"
  trap 'rm -f "$tmp"; trap - RETURN' RETURN
  fleet_json sops | secrets_render >"$tmp"

  if [ -f .sops.yaml ] && cmp -s "$tmp" .sops.yaml; then
    echo ".sops.yaml is up to date"
    return 0
  fi
  if [ "$check" = 1 ]; then
    diff -u .sops.yaml "$tmp" || true
    die ".sops.yaml is stale; run fleetl secrets sync"
  fi

  if [ -f .sops.yaml ]; then diff -u .sops.yaml "$tmp" || true; fi
  install -m 644 "$tmp" .sops.yaml
  echo "wrote .sops.yaml"

  # Re-key every store that exists, so their data keys match the rules.
  local store failed=()
  while IFS= read -r store; do
    if [ -f "$store" ]; then
      echo "updating keys of $store"
      sops updatekeys -y "$store" || failed+=("$store")
    fi
  done < <(fleet_json sops | jq -r '.stores[].path')
  if [ "${#failed[@]}" -gt 0 ]; then
    die "could not update the keys of: ${failed[*]}"
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

# Is a secret of a generator in a store already?  sops leaves the keys of a
# store in the clear, only the values are encrypted.
has_secret() { # <store file> <yq path>
  [ -f "$1" ] && yq -e "$2" "$1" >/dev/null 2>&1
}

# Run the host's generators whose files are missing (or the ones named;
# --force runs them again).  Public files land next to host.nix, secret ones
# in secrets.yaml (as <generator>/<file>) or identity.yaml (as <file>).  A
# store that does not exist yet is written once for everything generated, so
# a fresh host needs no key of the admin's; adding to an existing store does.
host_generate() {
  in_repo
  local name="${1:?usage: fleetl host generate <name> [--force] [<generator>...]}" force=0
  shift
  local -a wanted=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      -*) usage ;;
      *) wanted+=("$1"); shift ;;
    esac
  done
  local dir="nixos/hosts/$name"
  [ -d "$dir" ] || die "no $dir"
  local host gens
  host="$(fleet_json "hosts.$name")" || die "no host $name"
  gens="$(fleet_json generators)"
  if [ "${#wanted[@]}" = 0 ]; then
    mapfile -t wanted < <(jq -r '.generators[]' <<<"$host")
  fi

  local tmp
  tmp="$(mktemp -d)"
  # (a RETURN trap outlives the function: clear it when it has run)
  trap 'rm -rf "$tmp"; trap - RETURN' RETURN
  chmod 700 "$tmp"

  # 1. run what is missing; public files go next to host.nix right away
  local gen spec f secret st
  local -a ran=()
  for gen in "${wanted[@]}"; do
    spec="$(jq -e --arg g "$gen" '.[$g]' <<<"$gens")" || die "no generator '$gen'"

    if [ "$force" = 0 ]; then
      local missing=0
      while IFS=$'\t' read -r f secret st; do
        if [ "$secret" = true ]; then
          if [ "$st" = identity ]; then
            has_secret "$dir/identity.yaml" ".[\"$f\"]" || missing=1
          else
            has_secret "$dir/secrets.yaml" ".[\"$gen\"][\"$f\"]" || missing=1
          fi
        else
          [ -e "$dir/$f" ] || missing=1
        fi
      done < <(jq -r '.files | to_entries[] | [.key, (.value.secret // false | tostring), (.value.store // "secrets")] | @tsv' <<<"$spec")
      if [ "$missing" = 0 ]; then
        echo "$gen: $name has its files"
        continue
      fi
    fi

    echo "$gen: generating for $name"
    mkdir -p "$tmp/$gen"
    HOST="$name" nix run ".#generate-$gen" -- "$tmp/$gen"
    while IFS= read -r f; do
      install -m 644 "$tmp/$gen/$f" "$dir/$f"
    done < <(jq -r '.files | to_entries[] | select(.value.secret != true) | .key' <<<"$spec")
    ran+=("$gen")
  done
  [ "${#ran[@]}" = 0 ] && return 0

  # the public files may have made the host a recipient
  git add -N "$dir"
  fleet_json sops | secrets_render >.sops.yaml

  # 2. the secret files, into the stores: all at once into a new store, one
  #    by one into an existing one
  local store path doc
  for store in secrets identity; do
    path="$dir/$store.yaml"
    doc="$tmp/$store.yaml"
    : >"$doc"
    local -a sets=()
    for gen in "${ran[@]}"; do
      spec="$(jq --arg g "$gen" '.[$g]' <<<"$gens")"
      while IFS= read -r f; do
        if [ "$store" = identity ]; then
          F="$f" V="$(cat "$tmp/$gen/$f")" yq -i '.[strenv(F)] = strenv(V)' "$doc"
          sets+=("[\"$f\"]	$tmp/$gen/$f")
        else
          G="$gen" F="$f" V="$(cat "$tmp/$gen/$f")" yq -i '.[strenv(G)][strenv(F)] = strenv(V)' "$doc"
          sets+=("[\"$gen\"][\"$f\"]	$tmp/$gen/$f")
        fi
      done < <(jq -r --arg s "$store" \
        '.files | to_entries[] | select(.value.secret == true and (.value.store // "secrets") == $s) | .key' <<<"$spec")
    done
    [ "${#sets[@]}" = 0 ] && continue
    if [ -f "$path" ]; then
      echo "$store.yaml: adding ${#sets[@]} secret(s) (needs your key)"
      local entry
      for entry in "${sets[@]}"; do
        sops set "$path" "${entry%%	*}" "$(jq -Rs . <"${entry#*	}")" ||
          die "could not add ${entry%%	*} to $path"
      done
    else
      echo "$store.yaml: written"
      sops --encrypt --filename-override "$path" --output "$path" "$doc"
      git add -N "$path"
    fi
  done
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

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"; trap - RETURN' RETURN
  chmod 700 "$tmp"

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
    cut -d' ' -f1,2 "$sshkey" >"$dir/ssh.pub"
  elif ssh-add -L >"$dir/ssh.pub" 2>/dev/null; then
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
      show) show hosts "${3:?usage: fleetl host show <name>}" ;;
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
