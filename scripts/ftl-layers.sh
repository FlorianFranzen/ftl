# ftl-layers: install and update this host's layers - independently
# versioned Nix profiles under /nix/var/nix/profiles/layers/<name>.
#
# Usage:
#   ftl-layers update [<sha>]   resolve layers at <sha> (default: last target)
#   ftl-layers hook             comin postDeploymentCommand entry point
#   ftl-layers list             show installed layers and their revisions
#   ftl-layers rollback <name>  switch a layer back to its previous generation
#
# Environment (baked in by the ftl.layers NixOS module):
#   FTL_REPO_URL  FTL_SYSTEM  FTL_LAYERS ("name:kind ...")
#   FTL_STATE_DIR (/var/lib/ftl-layers)  FTL_PROFILE_DIR (/nix/var/nix/profiles/layers)
#   FTL_KEEP_GENERATIONS  FTL_VERIFY_MODE (none|ssh|gpg)  FTL_ALLOWED_SIGNERS
#   FTL_GPG_HOME  FTL_NTFY_URL
#
# A layer's revision comes from ftl-layers.json at the target commit:
#   { "<layer>": "latest" | "<sha>" }   (missing entry = "latest")
# A pinned sha must be an ancestor of the target commit.

: "${FTL_STATE_DIR:=/var/lib/ftl-layers}"
: "${FTL_PROFILE_DIR:=/nix/var/nix/profiles/layers}"
: "${FTL_KEEP_GENERATIONS:=5}"
: "${FTL_VERIFY_MODE:=none}"
: "${FTL_LAYERS:=}"

mirror="$FTL_STATE_DIR/repo.git"
state="$FTL_STATE_DIR/state.json"
target_file="$FTL_STATE_DIR/target"

log() { echo "ftl-layers: $*" >&2; }

notify() {
  [ -n "${FTL_NTFY_URL:-}" ] || return 0
  curl -fsS -m 10 -H "Title: ftl-layers: $(hostname)" -d "$1" "$FTL_NTFY_URL" >/dev/null ||
    log "ntfy notification failed"
}

kind_of() { # name
  local entry
  for entry in $FTL_LAYERS; do
    [ "${entry%%:*}" = "$1" ] && echo "${entry#*:}" && return 0
  done
  return 1
}

g() { git -C "$mirror" "$@"; }

ensure_mirror() {
  mkdir -p "$FTL_STATE_DIR" "$FTL_PROFILE_DIR"
  [ -d "$mirror" ] || git init --quiet --bare "$mirror"
  g fetch --quiet "${FTL_REPO_URL:?}" '+refs/heads/*:refs/remotes/origin/*'
}

verify_commit() { # sha
  local fmt=() validity
  case "$FTL_VERIFY_MODE" in
  none) return 0 ;;
  ssh) fmt=(-c gpg.format=ssh -c "gpg.ssh.allowedSignersFile=${FTL_ALLOWED_SIGNERS:?}") ;;
  gpg) export GNUPGHOME="${FTL_GPG_HOME:?}" ;;
  *)
    log "unknown FTL_VERIFY_MODE '$FTL_VERIFY_MODE'"
    return 1
    ;;
  esac
  validity="$(g "${fmt[@]}" log -1 --format='%G?' "$1")"
  # ssh: only G = signed by a listed principal (U = valid but unlisted key).
  # gpg: keyring holds only trusted keys, U only means "no ownertrust".
  case "$FTL_VERIFY_MODE:$validity" in
  *:G | gpg:U) return 0 ;;
  *)
    log "commit $1 has an invalid or untrusted signature (status=$validity)"
    return 1
    ;;
  esac
}

meta_units() { # profile path -> unit names
  local m="$1/share/ftl-layer/meta.json"
  [ -f "$m" ] && jq -r '.units[]' "$m"
  return 0
}

write_state() { # name rev outPath status
  [ -f "$state" ] || echo '{}' >"$state"
  jq --arg n "$1" --arg rev "$2" --arg out "$3" --arg st "$4" --arg t "$(date -u +%FT%TZ)" \
    '.layers[$n] = {rev:$rev, outPath:(if $out=="" then null else $out end), status:$st, checked:$t}' \
    "$state" >"$state.tmp" && mv "$state.tmp" "$state"
}

cmd_update() {
  local sha="${1:-}" pins_json failures=0 reload=0 entry name kind pin rev cur out
  local -a restart_units=() stop_units=()

  ensure_mirror
  if [ -z "$sha" ] && [ -f "$target_file" ]; then sha="$(cat "$target_file")"; fi
  if [ -z "$sha" ]; then
    log "no target revision known yet (comin has not deployed, none given)"
    return 1
  fi
  sha="$(g rev-parse --verify "$sha^{commit}")" || {
    log "target $sha not found in $FTL_REPO_URL"
    return 1
  }
  verify_commit "$sha" || return 1
  echo "$sha" >"$target_file"
  [ -f "$state" ] || echo '{}' >"$state"
  jq --arg sha "$sha" '.target = $sha' "$state" >"$state.tmp" && mv "$state.tmp" "$state"

  pins_json="$(g show "$sha:ftl-layers.json" 2>/dev/null || echo '{}')"

  for entry in $FTL_LAYERS; do
    name="${entry%%:*}"
    kind="${entry#*:}"
    pin="$(jq -r --arg n "$name" '.[$n] // "latest"' <<<"$pins_json")"
    if [ "$pin" = "latest" ]; then
      rev="$sha"
    else
      if ! rev="$(g rev-parse --verify --quiet "$pin^{commit}")" ||
        ! g merge-base --is-ancestor "$rev" "$sha"; then
        log "REFUSING layer $name: pin $pin is not an ancestor of $sha"
        write_state "$name" "$pin" "" "refused"
        failures=$((failures + 1))
        continue
      fi
    fi

    if ! out="$(nix build --no-link --print-out-paths \
      "git+file://$mirror?rev=$rev#nixosLayers.$FTL_SYSTEM.$name")"; then
      log "layer $name failed to build at $rev; keeping current generation"
      write_state "$name" "$rev" "" "failed"
      failures=$((failures + 1))
      continue
    fi

    cur="$(readlink -f "$FTL_PROFILE_DIR/$name" 2>/dev/null || true)"
    if [ "$cur" = "$out" ]; then
      write_state "$name" "$rev" "$out" "ok"
      continue
    fi

    if [ "$kind" = services ]; then
      reload=1
      while read -r u; do
        [ -n "$u" ] || continue
        meta_units "$out" | grep -qxF "$u" || stop_units+=("$u")
      done < <([ -n "$cur" ] && meta_units "$cur")
      while read -r u; do
        if [ -n "$u" ]; then restart_units+=("$u"); fi
      done < <(meta_units "$out")
    fi

    nix-env --profile "$FTL_PROFILE_DIR/$name" --set "$out"
    nix-env --profile "$FTL_PROFILE_DIR/$name" --delete-generations "+$FTL_KEEP_GENERATIONS" >/dev/null 2>&1 || true
    log "layer $name -> $rev ($out)"
    write_state "$name" "$rev" "$out" "ok"
  done

  if [ "${#stop_units[@]}" -gt 0 ]; then systemctl stop "${stop_units[@]}" || true; fi
  if [ "$reload" = 1 ]; then systemctl daemon-reload; fi
  if [ "${#restart_units[@]}" -gt 0 ]; then
    systemctl restart "${restart_units[@]}" || failures=$((failures + 1))
  fi

  if [ "$failures" -gt 0 ]; then
    notify "$failures layer(s) could not be updated to $sha; previous generations kept"
    return 1
  fi
}

cmd_hook() {
  # comin postDeploymentCommand: only act on successful deployments.
  if [ "${COMIN_STATUS:-}" != "done" ] || [ -z "${COMIN_GIT_SHA:-}" ]; then
    log "comin deployment status '${COMIN_STATUS:-}', not updating layers"
    return 0
  fi
  mkdir -p "$FTL_STATE_DIR"
  echo "$COMIN_GIT_SHA" >"$target_file"
  systemctl start --no-block ftl-layers-update.service
}

cmd_list() {
  local entry name cur
  [ -f "$state" ] && echo "target: $(jq -r '.target // "-"' "$state")"
  for entry in $FTL_LAYERS; do
    name="${entry%%:*}"
    cur="$(readlink -f "$FTL_PROFILE_DIR/$name" 2>/dev/null || echo '-')"
    if [ -f "$state" ]; then
      jq -r --arg n "$name" --arg k "${entry#*:}" --arg cur "$cur" \
        '"\($n) [\($k)] rev=\(.layers[$n].rev // "-" | .[0:12]) status=\(.layers[$n].status // "-") \($cur)"' "$state"
    else
      echo "$name [${entry#*:}] $cur"
    fi
  done
}

cmd_rollback() {
  local name="${1:?usage: ftl-layers rollback <name>}" kind before after
  kind="$(kind_of "$name")" || {
    log "unknown layer '$name'"
    return 1
  }
  before="$(readlink -f "$FTL_PROFILE_DIR/$name")"
  nix-env --profile "$FTL_PROFILE_DIR/$name" --rollback
  after="$(readlink -f "$FTL_PROFILE_DIR/$name")"
  write_state "$name" "rollback" "$after" "rolled-back"
  if [ "$kind" = services ]; then
    local -a units=()
    while read -r u; do
      if [ -n "$u" ]; then units+=("$u"); fi
    done < <(meta_units "$after")
    while read -r u; do
      [ -n "$u" ] || continue
      meta_units "$after" | grep -qxF "$u" || systemctl stop "$u" || true
    done < <(meta_units "$before")
    systemctl daemon-reload
    if [ "${#units[@]}" -gt 0 ]; then systemctl restart "${units[@]}"; fi
  fi
  log "layer $name rolled back: $before -> $after"
}

case "${1:-}" in
update)
  shift
  cmd_update "$@"
  ;;
hook) cmd_hook ;;
list) cmd_list ;;
rollback)
  shift
  cmd_rollback "$@"
  ;;
*)
  grep '^#' "$0" | sed -n '2,10p' | sed 's/^# \{0,1\}//'
  exit 2
  ;;
esac
