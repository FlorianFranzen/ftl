# ftl-pipeline: update one lane of one environment repo, build its manifest
# attrs, publish results to the binary cache and (optionally) fast-forward the
# deployed branch, pinning layers that failed to their last green commit. Designed to run as a systemd oneshot; all configuration via FTL_*
# environment variables (set by the ftl.builder NixOS module).
#
# Required: FTL_REPO_NAME FTL_REPO_URL FTL_STATE_DIR FTL_STATUS_DIR FTL_SYSTEMS
# Optional: FTL_BRANCH (main) FTL_LANE (default) FTL_LANE_INPUTS ("" = all)
#           FTL_CACHE_DIR FTL_CACHE_SIGNED (1 when pushed paths get signed, by
#           nix-daemon or the sign command; nothing is pushed otherwise)
#           FTL_CACHE_DAEMON_SIGNED (1 when nix-daemon signs at build time)
#           FTL_CACHE_SIGN_COMMAND (run as `cmd <cache dir> <queue file>` after
#           each build) FTL_PROMOTE (0) FTL_KEEP_GENERATIONS (5)
#           FTL_SIGN_FORMAT (none|ssh|openpgp) FTL_SIGN_KEY FTL_GIT_NAME FTL_GIT_EMAIL
#           FTL_VERIFY_MODE (none|ssh|gpg) FTL_ALLOWED_SIGNERS FTL_VERIFY_GPG_HOME
#           FTL_DEPLOY_KEY FTL_KNOWN_HOSTS FTL_METRICS_FILE FTL_NTFY_URL
#           FTL_EVAL_WORKERS FTL_EXTRA_BUILD_ARGS

: "${FTL_BRANCH:=main}"
: "${FTL_LANE:=default}"
: "${FTL_LANE_INPUTS:=}"
: "${FTL_PROMOTE:=0}"
: "${FTL_KEEP_GENERATIONS:=5}"
: "${FTL_SIGN_FORMAT:=none}"
: "${FTL_VERIFY_MODE:=none}"
: "${FTL_EVAL_WORKERS:=2}"

state="$FTL_STATE_DIR/$FTL_REPO_NAME"
mirror="$state/mirror.git"
work="$state/work-$FTL_LANE"
status_file="$FTL_STATUS_DIR/$FTL_REPO_NAME.json"
jsonl="$state/promoted.jsonl"
now="$(date -u +%FT%TZ)"

mkdir -p "$state" "$FTL_STATUS_DIR"

log() { echo "ftl-pipeline[$FTL_REPO_NAME/$FTL_LANE]: $*" >&2; }

notify() {
  [ -n "${FTL_NTFY_URL:-}" ] || return 0
  curl -fsS -m 10 -H "Title: ftl: $FTL_REPO_NAME/$FTL_LANE" -d "$1" "$FTL_NTFY_URL" >/dev/null ||
    log "ntfy notification failed"
}

# ssh: never trust a host on first use (no tty means it would fail anyway,
# but say so explicitly), optionally pin the repos' host keys to one file.
ssh_cmd="ssh -o BatchMode=yes -o StrictHostKeyChecking=yes"
[ -n "${FTL_KNOWN_HOSTS:-}" ] && ssh_cmd="$ssh_cmd -o UserKnownHostsFile=$FTL_KNOWN_HOSTS"
[ -n "${FTL_DEPLOY_KEY:-}" ] && ssh_cmd="$ssh_cmd -i $FTL_DEPLOY_KEY -o IdentitiesOnly=yes"
export GIT_SSH_COMMAND="$ssh_cmd"

# Status pages are public: never publish credentials embedded in the repo URL.
repo_public="$(sed -E 's#^([a-z+]+://)[^/@]*@#\1#' <<<"$FTL_REPO_URL")"

verify_commit() { # sha -> 0 iff signed by a trusted key
  local validity
  case "$FTL_VERIFY_MODE" in
  none) return 0 ;;
  ssh)
    validity="$(git -c gpg.format=ssh -c "gpg.ssh.allowedSignersFile=${FTL_ALLOWED_SIGNERS:?}" \
      log -1 --format='%G?' "$1")"
    ;;
  gpg)
    validity="$(GNUPGHOME="${FTL_VERIFY_GPG_HOME:?}" git -c gpg.format=openpgp log -1 --format='%G?' "$1")"
    ;;
  *)
    log "unknown FTL_VERIFY_MODE '$FTL_VERIFY_MODE'"
    return 1
    ;;
  esac
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

# --- sync -------------------------------------------------------------------
if [ ! -d "$mirror" ]; then
  git clone --mirror "$FTL_REPO_URL" "$mirror"
else
  git -C "$mirror" fetch --prune origin
fi

# Leave any previous worktree before deleting it: the retry below re-execs
# this script from inside it.
cd "$state"
rm -rf "$work"
git clone --quiet --branch "$FTL_BRANCH" "$mirror" "$work"
cd "$work"
git remote add upstream "$FTL_REPO_URL"
git config user.name "${FTL_GIT_NAME:-ftl pipeline}"
git config user.email "${FTL_GIT_EMAIL:-ftl@localhost}"

sign_args=()
case "$FTL_SIGN_FORMAT" in
ssh)
  git config gpg.format ssh
  git config user.signingkey "$FTL_SIGN_KEY"
  sign_args=(-S)
  ;;
openpgp)
  git config gpg.format openpgp
  git config user.signingkey "$FTL_SIGN_KEY"
  sign_args=(-S)
  ;;
none) ;;
*)
  log "unknown FTL_SIGN_FORMAT '$FTL_SIGN_FORMAT'"
  exit 1
  ;;
esac

# --- status helpers ---------------------------------------------------------
attrs_json="$state/attrs-$FTL_LANE.json"
echo '{}' >"$attrs_json"

record_attr() { # name system importance host layer status outPath
  # Attrs present on several systems (layers) aggregate: ok only if ok everywhere.
  jq --arg n "$1" --arg sys "$2" --arg imp "$3" --arg host "$4" --arg layer "$5" \
    --arg st "$6" --arg out "$7" \
    '.[$n] = ((.[$n] // {systems:{}}) + {importance:$imp,
                host:(if $host=="" then null else $host end),
                layer:(if $layer=="" then null else $layer end)})
     | .[$n].systems[$sys] = {status:$st, outPath:(if $out=="" then null else $out end)}
     | .[$n].outPath = (if $out=="" then .[$n].outPath else $out end)
     | .[$n].status = ([.[$n].systems[].status] as $s
                       | if all($s[]; . == "ok") then "ok"
                         else ([$s[] | select(. != "ok")][0]) end)' \
    "$attrs_json" >"$attrs_json.tmp" && mv "$attrs_json.tmp" "$attrs_json"
}

finish() { # phase promoted
  local prev_file="$state/prev-status.json"
  [ -f "$status_file" ] && cp "$status_file" "$prev_file" || echo '{}' >"$prev_file"
  jq -n --arg env "$FTL_REPO_NAME" --arg repo "$repo_public" --arg lane "$FTL_LANE" \
    --arg run "$now" --arg candidate "$candidate" --arg candidateTree "$candidate_tree" \
    --arg phase "$1" \
    --argjson bumped "$bumped" --argjson promoted "${2:-false}" \
    --slurpfile attrs "$attrs_json" \
    '{environment:$env, repo:$repo, lane:$lane, run:$run, candidate:$candidate,
      candidateTree:$candidateTree, phase:$phase, bumped:($bumped==1),
      promoted:$promoted, attrs:$attrs[0]}' \
    >"$status_file.tmp" && mv "$status_file.tmp" "$status_file"

  # Prometheus textfile metrics
  if [ -n "${FTL_METRICS_FILE:-}" ]; then
    {
      echo "# TYPE ftl_attr_ok gauge"
      jq -r --arg env "$FTL_REPO_NAME" 'to_entries[] |
        "ftl_attr_ok{environment=\"\($env)\",attr=\"\(.key)\",importance=\"\(.value.importance)\"} \(if .value.status=="ok" then 1 else 0 end)"' \
        "$attrs_json"
      echo "# TYPE ftl_last_run_timestamp_seconds gauge"
      echo "ftl_last_run_timestamp_seconds{environment=\"$FTL_REPO_NAME\",lane=\"$FTL_LANE\"} $(date -u +%s)"
    } >"$FTL_METRICS_FILE.tmp" && mv "$FTL_METRICS_FILE.tmp" "$FTL_METRICS_FILE"
  fi

  # Notify on per-attr state transitions (and eval failures).
  local transitions
  transitions="$(jq -r -n --slurpfile prev "$prev_file" --slurpfile cur "$status_file" '
    ($prev[0].attrs // {}) as $p | ($cur[0].attrs // {}) as $c |
    $c | to_entries[] | select(.value.status != ($p[.key].status // .value.status)) |
    "\(.key): \($p[.key].status // "new") -> \(.value.status)"')"
  [ -n "$transitions" ] && notify "$transitions"
  return 0
}

# --- verify the base ---------------------------------------------------------
# Everything built here ends up under the builder's own signature, so the tip
# we build on must already carry a trusted one; otherwise the pipeline would
# turn write access to the forge into a fleet-wide signed deployment.
base_sha="$(git rev-parse HEAD)"
if ! verify_commit "$base_sha"; then
  candidate="$base_sha" candidate_tree="$(git rev-parse 'HEAD^{tree}')" bumped=0
  notify "REFUSING to build: tip $base_sha of $FTL_BRANCH is not signed by a trusted key"
  finish "unverified" false
  exit 1
fi

# --- bump -------------------------------------------------------------------
if [ -n "$FTL_LANE_INPUTS" ]; then
  # shellcheck disable=SC2086 # intentional word splitting of input names
  nix flake update $FTL_LANE_INPUTS
else
  nix flake update
fi

bumped=0
if ! git diff --quiet -- flake.lock; then
  git commit --quiet "${sign_args[@]}" -m "ftl(${FTL_LANE}): update flake.lock" -- flake.lock
  bumped=1
fi
candidate="$(git rev-parse HEAD)"
# Tree hash is stable across re-created bump commits (commit hashes are not).
candidate_tree="$(git rev-parse 'HEAD^{tree}')"

# Skip when this exact candidate content was already processed.
if [ -f "$status_file" ] && [ "$(jq -r '.candidateTree // ""' "$status_file")" = "$candidate_tree" ] &&
  [ "${FTL_FORCE:-0}" != 1 ]; then
  log "candidate tree $candidate_tree already processed; nothing to do"
  exit 0
fi
log "candidate $candidate (lock bumped: $bumped)"

# --- evaluate manifest ------------------------------------------------------
if ! nix eval --json .#ftlManifest >"$state/manifest.json" 2>"$state/eval-error.log"; then
  log "manifest evaluation failed"
  notify "manifest evaluation FAILED at $candidate: $(tail -c 500 "$state/eval-error.log")"
  finish "eval-failed" false
  exit 1
fi

# --- build ------------------------------------------------------------------
# Paths are signed by nix-daemon at build time (secret-key-files) and/or by
# FTL_CACHE_SIGN_COMMAND after the push (keys nix-daemon cannot hold, e.g. on a
# smartcard); this process never touches a key. Never publish unsigned paths:
# without either, build but skip the cache push.
cache_url=""
if [ -n "${FTL_CACHE_DIR:-}" ]; then
  if [ "${FTL_CACHE_SIGNED:-0}" = 1 ]; then
    cache_url="file://${FTL_CACHE_DIR}?compression=zstd&parallel-compression=true&want-mass-query=true&priority=20"
  else
    log "no cache signing configured (ftl.builder.cache.secretKeyFile or .signer.command); not pushing to the cache"
    notify "no cache signing key configured; builds are not pushed to the cache"
  fi
fi

# Sanity check of the daemon-side signing: a green path without any
# signature means the key setup is broken (clients would refuse it anyway).
unsigned_ok() { # outPath -> 0 iff the path carries no signature at all
  nix path-info --json "$1" 2>/dev/null |
    jq -e '[.. | objects | .signatures? // empty] | all(length == 0)' >/dev/null
}

required_red=0
unsigned=0
green_outs=()
for system in $FTL_SYSTEMS; do
  names="$(jq -r --arg s "$system" '(.attrs[$s] // {}) | keys[]' "$state/manifest.json")"
  [ -n "$names" ] || continue

  build_args=(
    --flake ".#checks.$system" --skip-cached --no-nom --retries 1
    --eval-workers "$FTL_EVAL_WORKERS"
    --result-file "$state/result-$system.json"
  )
  [ -n "$cache_url" ] && build_args+=(--copy-to "$cache_url")
  # shellcheck disable=SC2086 # optional extra args are intentionally split
  nix-fast-build "${build_args[@]}" ${FTL_EXTRA_BUILD_ARGS:-} \
    >"$state/build-$system.log" 2>&1 || log "nix-fast-build reported failures for $system"

  for checkName in $names; do
    entry="$(jq -c --arg s "$system" --arg n "$checkName" '.attrs[$s][$n]' "$state/manifest.json")"
    importance="$(jq -r '.importance' <<<"$entry")"
    host="$(jq -r '.host // ""' <<<"$entry")"
    layer="$(jq -r '.layer // ""' <<<"$entry")"

    if [ "$importance" = "ignored" ]; then
      record_attr "$checkName" "$system" "$importance" "$host" "$layer" "skipped" ""
      continue
    fi

    # Robust per-attr verdict: the attr is green iff its outPath evaluates
    # and is a valid (locally present) store path. Avoids depending on the
    # nix-fast-build result-file schema; flake eval cache keeps this cheap.
    st="eval-failed" out=""
    if out="$(nix eval --raw ".#checks.$system.$checkName.outPath" 2>/dev/null)"; then
      if nix-store --check-validity "$out" >/dev/null 2>&1; then
        st="ok"
        green_outs+=("$out")
        if [ -n "$cache_url" ] && [ "${FTL_CACHE_DAEMON_SIGNED:-0}" = 1 ] && unsigned_ok "$out"; then
          unsigned=$((unsigned + 1))
          log "$checkName built but carries no signature; check secret-key-files on nix-daemon"
        fi
      else
        st="build-failed"
      fi
    fi
    record_attr "$checkName" "$system" "$importance" "$host" "$layer" "$st" "$out"
    if [ "$importance" = "required" ] && [ "$st" != "ok" ]; then
      required_red=1
      log "required attr $checkName is $st"
    fi
  done
done
[ "$unsigned" = 0 ] || notify "$unsigned built path(s) carry no signature; nix-daemon's secret-key-files setup is broken"

# --- sign the push with keys nix-daemon cannot hold -----------------------
# The queue is the closure of every green path: that is what --copy-to pushed.
# The command gets the cache directory and the queue file; it may skip paths
# that are already signed. Failure is reported but not fatal: clients requiring
# this key refuse the unsigned narinfos, everything else keeps working.
if [ -n "$cache_url" ] && [ -n "${FTL_CACHE_SIGN_COMMAND:-}" ] && [ "${#green_outs[@]}" -gt 0 ]; then
  sign_queue="$state/sign-queue-$FTL_LANE"
  nix-store --query --requisites "${green_outs[@]}" | sort -u >"$sign_queue"
  log "signing $(wc -l <"$sign_queue") path(s) with the cache sign command"
  # shellcheck disable=SC2086 # the command may carry arguments
  if ! $FTL_CACHE_SIGN_COMMAND "$FTL_CACHE_DIR" "$sign_queue" >"$state/sign-$FTL_LANE.log" 2>&1; then
    log "cache sign command failed: $(tail -c 500 "$state/sign-$FTL_LANE.log")"
    notify "cache sign command FAILED: $(tail -c 300 "$state/sign-$FTL_LANE.log")"
  fi
fi

# --- promote ----------------------------------------------------------------
# Hosts follow $FTL_BRANCH with comin, which only accepts fast-forwards. The
# candidate (branch tip + signed lock bump) is pushed onto the branch when
# every required attr built. Layers never gate: ftl-layers.json pins a red
# layer to the last commit at which it built, so hosts keep running that.
promoted=false
if [ "$required_red" = 1 ]; then
  if [ "$FTL_PROMOTE" = 1 ]; then
    # One ref per lane, force-updated: a bookmark of the last red candidate,
    # not a growing history of them.
    git push --quiet --force upstream "$candidate:refs/heads/broken/$FTL_LANE"
  fi
  notify "required build FAILED at $candidate; $FTL_BRANCH not updated"
elif [ "$FTL_PROMOTE" = 1 ]; then
  green_file="$state/layers-green.json"
  [ -f "$green_file" ] || echo '{}' >"$green_file"

  layer_names="$(jq -r '[.attrs[][] | select(.kind == "layer") | .layer] | unique[]' "$state/manifest.json")"
  if [ -n "$layer_names" ]; then
    prev_pins="$(git show HEAD:ftl-layers.json 2>/dev/null || echo '{}')"
    new_pins='{}'
    for l in $layer_names; do
      st="$(jq -r --arg n "nixos-layer-$l" '.[$n].status // "missing"' "$attrs_json")"
      if [ "$st" = ok ]; then
        pin="latest"
      else
        pin="$(jq -r --arg l "$l" '.[$l] // "latest"' <<<"$prev_pins")"
        if [ "$pin" = latest ]; then
          pin="$(jq -r --arg l "$l" --arg b "$base_sha" '.[$l] // $b' "$green_file")"
        fi
        log "layer $l is $st; pinned to $pin"
      fi
      new_pins="$(jq -S --arg l "$l" --arg p "$pin" '.[$l] = $p' <<<"$new_pins")"
    done
    if [ "$new_pins" != "$(jq -S . <<<"$prev_pins" 2>/dev/null)" ]; then
      echo "$new_pins" >ftl-layers.json
      git add ftl-layers.json
      if [ "$bumped" = 1 ]; then
        git commit --quiet --amend --no-edit "${sign_args[@]}"
      else
        git commit --quiet "${sign_args[@]}" -m "ftl(${FTL_LANE}): update layer pins" -- ftl-layers.json
      fi
      candidate="$(git rev-parse HEAD)"
    fi
  fi

  pushed=false
  if [ "$candidate" = "$base_sha" ]; then
    promoted=true
  elif git push --quiet upstream "HEAD:refs/heads/$FTL_BRANCH"; then
    promoted=true
    pushed=true
    log "pushed $candidate onto $FTL_BRANCH"
  elif [ "${FTL_RETRIED:-0}" != 1 ]; then
    log "$FTL_BRANCH moved during the run; rebuilding on top of the new tip"
    export FTL_RETRIED=1 FTL_FORCE=1
    exec "$0" "$@"
  else
    notify "could not fast-forward $FTL_BRANCH to $candidate (moved twice); retrying next run"
  fi

  if [ "$promoted" = true ]; then
    for l in $layer_names; do
      if [ "$(jq -r --arg n "nixos-layer-$l" '.[$n].status // ""' "$attrs_json")" = ok ]; then
        jq --arg l "$l" --arg c "$candidate" '.[$l] = $c' "$green_file" >"$green_file.tmp" &&
          mv "$green_file.tmp" "$green_file"
      fi
    done
  fi
  if [ "$pushed" = true ]; then
    # Record promoted generations (per attr and system) for cache retention.
    jq -r --arg rev "$candidate" --arg date "$now" \
      'to_entries[] | .key as $a | .value.systems | to_entries[] |
       select(.value.status == "ok") |
       {attr:"\($a)@\(.key)", rev:$rev, date:$date, outPath:.value.outPath} | @json' \
      "$attrs_json" >>"$jsonl"
    if [ -n "$cache_url" ]; then
      ftl-cache-retention "$FTL_CACHE_DIR" "$jsonl" "$FTL_KEEP_GENERATIONS" ||
        log "cache retention failed (non-fatal)"
    fi
  fi
fi

finish "done" "$promoted"
log "run complete (required_red=$required_red promoted=$promoted)"
[ "$required_red" = 0 ]
