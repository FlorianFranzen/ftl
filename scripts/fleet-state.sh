# fleet-state: the host's side of fleet.state, as root.
#
#   fleet-state list                       the entries: kind, path, where, service, backup
#   fleet-state backup [--all|<entry>...]  back entries up, each from a snapshot of
#                                          itself; --all: every entry with backup = true,
#                                          then prune by retention and write the metrics
#   fleet-state init                       create the backup repositories (once per host)
#   fleet-state snapshots [<entry>]        the backups of an entry, or of the whole host
#
# What the host keeps is described by /etc/fleet-state/state.json (written by
# the state module), its backups by /etc/fleet-state/backup.json and the rustic
# profiles /etc/rustic/<kind>.toml (the backup module).  A backup is a rustic
# snapshot of the entry's content under its real path, labelled with the
# entry's name, recorded for this host, and tagged fleet-entry:<entry> and
# fleet-service:<service>.

conf="${FLEET_STATE_CONF:-/etc/fleet-state}"
state_json="$conf/state.json"
backup_json="$conf/backup.json"
profiles="${FLEET_STATE_PROFILES:-/etc/rustic}"

usage() {
  sed -n '/^# fleet-state:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

die() {
  echo "fleet-state: $*" >&2
  exit 1
}

log() { echo "fleet-state: $*" >&2; }

[ -f "$state_json" ] || die "no $state_json: this host keeps no fleet.state"
backend="$(jq -r .backend "$state_json")"
host="$(jq -r .host "$state_json")"
device="$(jq -r '.device // empty' "$state_json")"

# --- entries -------------------------------------------------------------------

has_entry() { jq -e --arg n "$1" '.entries | has($n)' "$state_json" >/dev/null; }

need_entry() { has_entry "$1" || die "no entry '$1' on $host (fleet-state list)"; }

field() { # <entry> <field>
  jq -r --arg n "$1" --arg f "$2" '.entries[$n][$f] // empty' "$state_json"
}

entries_where() { # <jq condition on an entry>
  jq -r ".entries | to_entries[] | select(.value | $1) | .key" "$state_json"
}

# --- scratch space and cleanup -------------------------------------------------

# Everything temporary (snapshots, their mount points, the btrfs top level)
# is undone on any exit, a failure included, last made first undone.  A
# subshell that takes snapshots of its own runs `scoped`, so that they go
# when it ends.
scratch="$(mktemp -d /run/fleet-state.XXXXXX)"
chmod 700 "$scratch"
cleanups=()
run_cleanups() {
  local i
  for ((i = ${#cleanups[@]} - 1; i >= 0; i--)); do
    eval "${cleanups[$i]}" || log "cleanup failed: ${cleanups[$i]}"
  done
  cleanups=()
}
cleanup() {
  run_cleanups
  # never into a mount that failed to go (the btrfs top level holds everything)
  rm -rf --one-file-system "$scratch"
}
trap cleanup EXIT
# a signal (a reader gone, ^C) ends the run through the same cleanup
trap 'exit 129' HUP PIPE
trap 'exit 130' INT
trap 'exit 143' TERM

scoped() { # <command...>: in a subshell, with its own cleanups
  (
    cleanups=()
    trap run_cleanups EXIT
    "$@"
  )
}

# One mutating fleet-state at a time (snapshot names are fixed).
lock() {
  exec 9>/run/fleet-state.lock
  flock -n 9 || { log "waiting for another fleet-state"; flock 9; }
}

# btrfs: the top level of the filesystem, where @apps and @data live.
top=""
mount_top() {
  [ -n "$top" ] && return 0
  [ -n "$device" ] || die "no btrfs device"
  top="$scratch/top"
  mkdir -p "$top"
  mount -o subvolid=5 "$device" "$top"
  cleanups+=("umount '$top'")
}

# --- snapshots -----------------------------------------------------------------

# snapshot_take <entry> <tag>: a read-only snapshot of the entry itself (not
# of whatever is mounted at its path), in $snapdir until the end of the
# process (or of the `scoped` subshell).  A snapshot left over by an earlier
# run that died is replaced.
snapdir=""
snapshot_take() {
  local name="$1" tag="$2" loc
  loc="$(field "$name" location)"
  if [ "$backend" = zfs ]; then
    zfs list -H -o name "$loc" >/dev/null 2>&1 || die "$name: no dataset $loc"
    if zfs list -H -o name "$loc@$tag" >/dev/null 2>&1; then
      zfs destroy "$loc@$tag"
    fi
    zfs snapshot "$loc@$tag"
    cleanups+=("zfs destroy '$loc@$tag'")
    snapdir="$scratch/snap-$name"
    mkdir -p "$snapdir"
    mount -t zfs -o ro "$loc@$tag" "$snapdir"
    cleanups+=("umount '$snapdir' && rmdir '$snapdir'")
  else
    mount_top
    [ -d "$top/$loc" ] || die "$name: no subvolume $loc"
    mkdir -p "$top/@fleet-snapshots"
    snapdir="$top/@fleet-snapshots/$name@$tag"
    if [ -e "$snapdir" ]; then
      btrfs subvolume delete "$snapdir" >/dev/null
    fi
    btrfs subvolume snapshot -r "$top/$loc" "$snapdir" >/dev/null
    cleanups+=("btrfs subvolume delete '$snapdir' >/dev/null")
  fi
}

# --- backups -------------------------------------------------------------------

backup_on() { [ -f "$backup_json" ]; }

need_backup() { backup_on || die "backups are off on $host (fleet.backup.enable)"; }

profile() { echo "$profiles/$1"; }

backup_entry() { # <entry>
  local name="$1" kind path service tags
  kind="$(field "$name" kind)"
  path="$(field "$name" path)"
  service="$(field "$name" service)"
  tags="fleet-entry:$name"
  [ -n "$service" ] && tags="$tags,fleet-service:$service"
  [ -f "$(profile "$kind").toml" ] || die "$name: no repository for kind $kind"

  snapshot_take "$name" fleet-backup
  log "$name: backing up $path"
  rustic -P "$(profile "$kind")" backup --no-progress \
    --host "$host" --label "$name" --tag "$tags" --as-path "$path" "$snapdir"
}

cmd_backup() {
  need_backup
  local all=0 name
  local -a names=() failed=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all=1 ;;
      -*) usage ;;
      *) names+=("$1") ;;
    esac
    shift
  done
  if [ "$all" = 1 ]; then
    [ "${#names[@]}" = 0 ] || usage
    mapfile -t names < <(entries_where '.backup')
  fi
  [ "${#names[@]}" -gt 0 ] || die "nothing to back up (name entries, or --all)"
  for name in "${names[@]}"; do
    need_entry "$name"
    [ "$(field "$name" backup)" = true ] || die "$name is not backed up (backup = false)"
  done

  lock
  if [ "$backend" = btrfs ]; then mount_top; fi
  for name in "${names[@]}"; do
    # one failing entry does not keep the others from their backup
    scoped backup_entry "$name" || failed+=("$name")
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    die "backup failed: ${failed[*]}"
  fi
  [ "$all" = 1 ] || return 0

  local kind metrics
  for kind in $(jq -r '.kinds[]' "$backup_json"); do
    rustic -P "$(profile "$kind")" forget --prune --no-progress
  done

  # For monitors: when the last complete backup succeeded, and how many
  # snapshots each repository holds, so that history disappearing from it is
  # noticed although the backups themselves keep succeeding.
  metrics="$(jq -r '.metrics // empty' "$backup_json")"
  if [ -n "$metrics" ]; then
    install -d -m 0755 "$metrics"
    {
      echo "fleet_backup_last_success_timestamp_seconds $(date +%s)"
      for kind in $(jq -r '.kinds[]' "$backup_json"); do
        echo "fleet_backup_snapshots{kind=\"$kind\"} $(rustic -P "$(profile "$kind")" snapshots --json | jq '[.[].snapshots[]] | length')"
      done
    } >"$metrics/fleet-backup.prom.tmp"
    mv "$metrics/fleet-backup.prom.tmp" "$metrics/fleet-backup.prom"
  fi
}

# Repositories are only ever created here, never by a backup: a repository
# that has gone missing must fail the backup, not quietly be replaced.
cmd_init() {
  need_backup
  local kind
  for kind in $(jq -r '.kinds[]' "$backup_json"); do
    if rustic -P "$(profile "$kind")" cat config >/dev/null 2>&1; then
      echo "repository $kind exists already"
    else
      rustic -P "$(profile "$kind")" init
    fi
  done
}

cmd_snapshots() {
  need_backup
  local name="${1:-}" kind
  local -a filter=(--filter-host "$host")
  if [ -n "$name" ]; then
    need_entry "$name"
    filter+=(--filter-label "$name")
    rustic -P "$(profile "$(field "$name" kind)")" snapshots "${filter[@]}"
  else
    for kind in $(jq -r '.kinds[]' "$backup_json"); do
      echo "== $kind"
      rustic -P "$(profile "$kind")" snapshots "${filter[@]}"
    done
  fi
}

cmd_list() {
  jq -r '.entries | to_entries[] |
    "\(.key)\t\(.value.kind)\t\(.value.path)\t\(.value.location)\t\(.value.service // "-")\tbackup=\(.value.backup)"' \
    "$state_json" | column -t -s $'\t'
}

# --- dispatch ------------------------------------------------------------------

[ "$(id -u)" = 0 ] || die "run as root"

case "${1:-}" in
  list) cmd_list ;;
  backup) shift; cmd_backup "$@" ;;
  init) cmd_init ;;
  snapshots) shift; cmd_snapshots "$@" ;;
  -h | --help | help) usage 0 ;;
  *) usage ;;
esac
