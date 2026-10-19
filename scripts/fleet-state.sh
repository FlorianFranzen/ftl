# fleet-state: the host's side of fleet.state, as root.
#
#   fleet-state list                       the entries: kind, path, where, service, backup
#   fleet-state backup [--all|<entry>...]  back entries up, each from a snapshot of
#                                          itself; --all: every entry with backup = true,
#                                          then prune by retention and write the metrics
#   fleet-state init                       create the backup repositories (once per host)
#   fleet-state snapshots [<entry>]        the backups of an entry, or of the whole host
#   fleet-state restore <entry> [--snapshot <id>] [--from-host <host>] [--no-start]
#                                          put the entry back as a backup has it (the
#                                          latest by default): its units stopped, the
#                                          current content kept as a rollback snapshot,
#                                          files the backup does not have removed
#   fleet-state stop <entry>...            stop what uses the entries (their units, the
#                                          instances of template units, their sockets)
#   fleet-state start <entry>...           start it again
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

# --- units ---------------------------------------------------------------------

# The systemd units that use an entry, as they are now: its units (for a
# template `x@`, its running instances), and what triggers them (sockets,
# timers, paths), triggers first, so that stopping in this order leaves
# nothing to start them again.
units_of() { # <entry>
  local name="$1" u
  local -a services=() triggers=()
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    if [[ $u == *@ ]]; then
      mapfile -t -O "${#services[@]}" services < <(
        systemctl list-units --all --plain --no-legend --type=service "${u}*.service" | awk '{ print $1 }'
      )
      # an Accept=yes socket spawns the instances
      if systemctl cat "${u%@}.socket" >/dev/null 2>&1; then
        triggers+=("${u%@}.socket")
      fi
    else
      services+=("$u.service")
    fi
  done < <(jq -r --arg n "$name" '.entries[$n].units[]' "$state_json")
  for u in "${services[@]}"; do
    # shellcheck disable=SC2207
    triggers+=($(systemctl show -P TriggeredBy "$u"))
  done
  printf '%s\n' "${triggers[@]}" "${services[@]}" | awk 'NF && !seen[$0]++'
}

# stop_units <entry>...: stops what uses the entries, and records in
# $scratch/active what was running, for start_units.
stop_units() {
  local name u
  local -a units=()
  for name in "$@"; do
    mapfile -t -O "${#units[@]}" units < <(units_of "$name")
  done
  : >"$scratch/active"
  for u in "${units[@]}"; do
    if systemctl is-active --quiet "$u"; then
      echo "$u" >>"$scratch/active"
    fi
  done
  if [ "${#units[@]}" -gt 0 ]; then
    log "stopping ${units[*]}"
    systemctl stop "${units[@]}"
  fi
}

# start_units: what stop_units found running, triggers last.
start_units() {
  local -a units=()
  [ -f "$scratch/active" ] && mapfile -t units < <(tac "$scratch/active")
  if [ "${#units[@]}" -gt 0 ]; then
    log "starting ${units[*]}"
    systemctl start "${units[@]}"
  fi
}

cmd_stop() {
  [ $# -gt 0 ] || usage
  local name
  for name in "$@"; do need_entry "$name"; done
  stop_units "$@"
}

# Starting an entry's units starts what they need, its mount included.
cmd_start() {
  [ $# -gt 0 ] || usage
  local name u
  local -a units=()
  for name in "$@"; do
    need_entry "$name"
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      if [[ $u == *@ ]]; then
        systemctl cat "${u%@}.socket" >/dev/null 2>&1 && units+=("${u%@}.socket")
      else
        units+=("$u.service")
      fi
    done < <(jq -r --arg n "$name" '.entries[$n].units[]' "$state_json")
  done
  if [ "${#units[@]}" -gt 0 ]; then
    systemctl start "${units[@]}"
  fi
}

# --- mounts --------------------------------------------------------------------

# The entry mounted at its path, from its own dataset or subvolume (and not,
# say, an empty directory on the root filesystem).
need_mounted() { # <entry>
  local name="$1" path loc source
  path="$(field "$name" path)"
  loc="$(field "$name" location)"
  systemctl start "$(systemd-escape --path --suffix=mount "$path")"
  source="$(findmnt -n -o SOURCE --mountpoint "$path" || true)"
  if [ "$backend" = zfs ]; then
    [ "$source" = "$loc" ] || die "$name: $path is not $loc (mounted: ${source:-nothing})"
  else
    [[ $source == *"[/$loc]" ]] || die "$name: $path is not $loc (mounted: ${source:-nothing})"
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

# The rustic snapshot of an entry: the latest of the host's (or another
# host's, by name), or the one given by id (a prefix will do).  Prints its id.
find_snapshot() { # <profile> <entry> <host> <id or latest>
  local profile="$1" name="$2" from="$3" want="$4" json
  json="$(rustic -P "$profile" snapshots --json --filter-host "$from" --filter-label "$name")"
  jq -r --arg want "$want" '
    [.[].snapshots[]] | sort_by(.time) |
    if $want == "latest" then last else map(select(.id | startswith($want))) | if length == 1 then .[0] else null end end |
    if . == null then empty else .id end' <<<"$json"
}

cmd_restore() {
  need_backup
  local name="" want=latest from="$host" start=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --snapshot) want="${2:?--snapshot needs an id}"; shift ;;
      --from-host) from="${2:?--from-host needs a host}"; shift ;;
      --no-start) start=0 ;;
      -*) usage ;;
      *) [ -z "$name" ] || usage; name="$1" ;;
    esac
    shift
  done
  [ -n "$name" ] || usage
  need_entry "$name"

  local kind path loc p id stamp rollback
  kind="$(field "$name" kind)"
  path="$(field "$name" path)"
  loc="$(field "$name" location)"
  p="$(profile "$kind")"
  [ -f "$p.toml" ] || die "$name: no repository for kind $kind"
  id="$(find_snapshot "$p" "$name" "$from" "$want")"
  [ -n "$id" ] || die "$name: no snapshot '$want' of $from (fleet-state snapshots $name)"
  log "$name: restoring snapshot ${id:0:8} of $from into $path"

  lock
  need_mounted "$name"
  stop_units "$name"

  # The content as it was, to go back to: kept, not part of the cleanups.
  stamp="$(date +%Y%m%dT%H%M%S)"
  if [ "$backend" = zfs ]; then
    rollback="$loc@fleet-pre-restore-$stamp"
    zfs snapshot "$rollback"
  else
    mount_top
    mkdir -p "$top/@fleet-snapshots"
    rollback="@fleet-snapshots/$name@pre-restore-$stamp"
    btrfs subvolume snapshot -r "$top/$loc" "$top/$rollback" >/dev/null
  fi
  log "$name: what was there is kept as $rollback"

  if ! rustic -P "$p" restore --no-progress --delete --numeric-id "$id:$path" "$path"; then
    log "$name: the restore failed; its units stay stopped"
    die "$name: back to what was there: $(rollback_hint "$name" "$rollback")"
  fi
  if [ "$start" = 1 ]; then
    start_units
  else
    log "$name: restored; its units stay stopped (fleet-state start $name)"
  fi
}

rollback_hint() { # <entry> <rollback snapshot>
  if [ "$backend" = zfs ]; then
    echo "zfs rollback -r $2"
  else
    echo "replace the subvolume $(field "$1" location) with a writable snapshot of $2 (btrfs subvolume snapshot)"
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
  restore) shift; cmd_restore "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  start) shift; cmd_start "$@" ;;
  -h | --help | help) usage 0 ;;
  *) usage ;;
esac
