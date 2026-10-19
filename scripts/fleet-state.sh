# fleet-state: the host's side of fleet.state, as root.
#
#   fleet-state list                       the entries, and the copies kept aside
#   fleet-state size <entry>...            bytes each entry holds
#   fleet-state stop <entry>...            stop what uses the entries (their units, their
#                                          sockets, timers and paths, what needs them), and
#                                          keep their units from starting until start
#   fleet-state start <entry>...           start again what stop stopped
#
# Backups (fleet.backup):
#
#   fleet-state backup --all|<entry>...    back entries up, each from a snapshot of itself;
#                                          --all: every entry with backup = true, then
#                                          prune by retention and write the metrics
#   fleet-state init                       create the backup repositories (once per host)
#   fleet-state snapshots [<entry>]        the backups of an entry, or of the whole host
#   fleet-state restore <entry> [--snapshot <id>] [--from-host <host>] [--no-start]
#                                          put the entry back as a backup has it (the
#                                          latest by default): restored into a new dataset
#                                          or subvolume, then swapped in for the current
#                                          one, which is kept aside
#   fleet-state rollback <entry> [<aside>] swap a copy kept aside (the newest by
#                                          default) back in; the current one goes aside
#   fleet-state discard <aside>            destroy a copy kept aside
#
# Moving an entry to another host (fleetl service move drives these):
#
#   fleet-state send <entry>               the entry, from a snapshot of it, as a tar
#                                          stream on stdout
#   fleet-state receive <entry> <kind> [--replace]
#                                          a tar stream on stdin into a new dataset or
#                                          subvolume for the entry, which this host need
#                                          not declare yet; an existing one is refused,
#                                          or with --replace swapped out and kept aside
#   fleet-state freeze <entry>...          stopped, blocked and read-only: the copy left
#                                          behind cannot change any more (until a reboot
#                                          lifts the block, the read-only stays)
#   fleet-state thaw <entry>...            undo freeze
#   fleet-state drop <entry> <kind>        destroy what a move left behind of an entry
#                                          this host no longer declares
#
# What the host keeps is described by /etc/fleet-state/state.json (written by
# the state module), its backups by /etc/fleet-state/backup.json and the rustic
# profiles /etc/rustic/<kind>.toml (the backup module).  A backup is a rustic
# snapshot of the entry's content under its real path, labelled with the
# entry's name, recorded for this host, and tagged fleet-entry:<entry> and
# fleet-service:<service>.  Copies kept aside are <dataset or subvolume>.aside-<time>.

conf="${FLEET_STATE_CONF:-/etc/fleet-state}"
state_json="$conf/state.json"
backup_json="$conf/backup.json"
profiles="${FLEET_STATE_PROFILES:-/etc/rustic}"
# what stop stopped and blocked, for start (gone with a reboot, as the blocks
# are: drop-ins in /run, which NixOS's units in /etc cannot override, unlike
# runtime masks)
records=/run/fleet-state
dropins=/run/systemd/system

usage() {
  sed -n '/^# fleet-state:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

die() {
  echo "fleet-state: $*" >&2
  exit 1
}

log() { echo "fleet-state: $*" >&2; }

case "${1:-}" in
  -h | --help | help) usage 0 ;;
  "") usage ;;
esac
# errexit in command substitutions too
shopt -s inherit_errexit
[ "$(id -u)" = 0 ] || die "run as root"
[ -f "$state_json" ] || die "no $state_json: this host keeps no fleet.state"
backend="$(jq -r .backend "$state_json")"
host="$(jq -r .host "$state_json")"
device="$(jq -r '.device // empty' "$state_json")"
pool="$(jq -r '.pool // empty' "$state_json")"

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
# step that may fail without ending the run (one entry of many) runs
# `scoped`: in a subshell with its own cleanups, its status in $scoped_rc.
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

# Never call it as a condition (`scoped ... || ...`, `if scoped`): bash turns
# errexit off for everything run in one, the subshell included, and a failed
# step would carry on.  It returns 0; the status is $scoped_rc.
scoped_rc=0
scoped() { # <command...>
  set +e
  (
    set -e
    cleanups=()
    trap run_cleanups EXIT
    "$@"
  )
  scoped_rc=$?
  set -e
}

# One fleet-state changing things at a time.
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

# --- where entries live --------------------------------------------------------

# The dataset or subvolume of an entry by name and kind, declared or not.
location_of() { # <entry> <kind>
  local parent
  parent="$(jq -r --arg k "$2" '.parents[$k] // empty' "$state_json")"
  [ -n "$parent" ] || die "no kind '$2' (state or data)"
  if [ "$backend" = zfs ]; then
    echo "$pool/$parent/$1"
  else
    echo "@$parent/$1"
  fi
}

location_exists() { # <location>
  if [ "$backend" = zfs ]; then
    zfs list -H -o name "$1" >/dev/null 2>&1
  else
    mount_top
    btrfs subvolume show "$top/$1" >/dev/null 2>&1
  fi
}

# A free name next to a location for a copy kept aside.
aside_name() { # <location>
  local base n=1 name
  base="$1.aside-$(date +%Y%m%dT%H%M%S)"
  name="$base"
  while location_exists "$name"; do
    n=$((n + 1))
    name="$base-$n"
  done
  echo "$name"
}

# The copies of a location kept aside, oldest first.
asides_of() { # <location>
  if [ "$backend" = zfs ]; then
    zfs list -H -o name -d 1 "${1%/*}" 2>/dev/null | grep -F "$1.aside-" | sort || true
  else
    mount_top
    local d
    for d in "$top/$1".aside-*; do
      if [ -e "$d" ]; then echo "${d#"$top/"}"; fi
    done | sort
  fi
}

# A new, empty dataset (mountpoint=legacy, as the state module makes them)
# or subvolume.
create_location() { # <location>
  local parent="${1%/*}"
  if [ "$backend" = zfs ]; then
    if ! zfs list -H -o name "$parent" >/dev/null 2>&1; then
      zfs create -o canmount=off -o mountpoint=none "$parent"
    fi
    zfs create -o mountpoint=legacy "$1"
  else
    mount_top
    if ! btrfs subvolume show "$top/$parent" >/dev/null 2>&1; then
      btrfs subvolume create "$top/$parent" >/dev/null
    fi
    btrfs subvolume create "$top/$1" >/dev/null
  fi
}

# Where a location's content can be written: a scratch mount of the dataset,
# or the subvolume below the top level.  Not in a command substitution: the
# mount's cleanup has to reach this shell.
opened=""
open_location() { # <location>, in $opened
  if [ "$backend" = zfs ]; then
    opened="$scratch/open-${1//\//_}"
    mkdir -p "$opened"
    mount -t zfs "$1" "$opened"
    cleanups+=("! mountpoint -q '$opened' || umount '$opened'")
  else
    mount_top
    opened="$top/$1"
  fi
}

close_location() { # <directory from open_location>
  sync -f "$1"
  if [ "$backend" = zfs ]; then
    umount "$1"
  fi
}

rename_location() { # <from> <to>
  if [ "$backend" = zfs ]; then
    zfs rename "$1" "$2"
  else
    mount_top
    mv -T "$top/$1" "$top/$2"
  fi
}

# Destroys a dataset or subvolume with its snapshots; only for what fleet-state
# made itself or what it was asked to destroy by name.
destroy_location() { # <location>
  if [ "$backend" = zfs ]; then
    zfs destroy -r "$1"
  else
    mount_top
    btrfs property set -ts "$top/$1" ro false
    btrfs subvolume delete "$top/$1" >/dev/null
  fi
}

destroy_if_exists() { # <location>
  if location_exists "$1"; then
    destroy_location "$1"
  fi
}

# The properties the state module gives an entry's dataset.
apply_properties() { # <entry> <location>
  [ "$backend" = zfs ] || return 0
  local k v
  while IFS=$'\t' read -r k v; do
    if [ -n "$k" ]; then zfs set "$k=$v" "$2"; fi
  done < <(jq -r --arg n "$1" '.entries[$n].zfsProperties // {} | to_entries[] | [.key, .value] | @tsv' "$state_json")
}

# --- mounts --------------------------------------------------------------------

mount_unit() { systemd-escape --path --suffix=mount "$1"; }

# Is the entry's own dataset or subvolume mounted at its path (and not, say,
# an empty directory on the root filesystem, or another filesystem's)?
is_mounted() { # <entry>
  local path loc
  path="$(field "$1" path)"
  loc="$(field "$1" location)"
  mountpoint -q "$path" || return 1
  if [ "$backend" = zfs ]; then
    [ "$(findmnt -n -o SOURCE --mountpoint "$path")" = "$loc" ]
  else
    [ "$(findmnt -n -o FSROOT --mountpoint "$path")" = "/$loc" ] &&
      [ "$(findmnt -n -o UUID --mountpoint "$path")" = "$(blkid -s UUID -o value "$device")" ]
  fi
}

# --- units ---------------------------------------------------------------------

# An entry's units as declared: `x` is x.service, `x@` the template,
# anything with a suffix itself.
declared_units() { # <entry>
  local u
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    if [[ $u == *@ ]]; then
      echo "${u}.service"
    elif [[ $u == *.* ]]; then
      echo "$u"
    else
      echo "$u.service"
    fi
  done < <(jq -r --arg n "$1" '.entries[$n].units[]' "$state_json")
}

# What starts an entry's units: their sockets, timers and paths, and for a
# template the Accept=yes socket of the same name.
triggers_of() { # <entry>
  local u
  while IFS= read -r u; do
    if [[ $u == *@.service ]]; then
      if systemctl cat "${u%@.service}.socket" >/dev/null 2>&1; then
        echo "${u%@.service}.socket"
      fi
    else
      systemctl show -P TriggeredBy "$u" | tr ' ' '\n'
    fi
  done < <(declared_units "$1") | awk 'NF && !seen[$0]++'
}

# The units of an entry as they are now: a template's running instances.
running_units_of() { # <entry>
  local u
  while IFS= read -r u; do
    if [[ $u == *@.service ]]; then
      systemctl list-units --all --plain --no-legend --type=service "${u%.service}*.service" | awk '{ print $1 }'
    else
      echo "$u"
    fi
  done < <(declared_units "$1")
}

active_units() {
  systemctl list-units --state=active --plain --no-legend \
    --type=service,socket,timer,path,mount,automount | awk '{ print $1 }' | sort
}

# Blocked units refuse to start (an assertion in a drop-in) while the
# entry's record of them exists; unblock removes both.
block() { # <entry> <unit>...
  local name="$1" u
  shift
  printf '%s\n' "$@" >"$records/$name.blocked"
  for u in "$@"; do
    mkdir -p "$dropins/$u.d"
    printf '[Unit]\n# fleet-state stop %s (fleet-state start %s)\nAssertPathExists=!%s\n' \
      "$name" "$name" "$records/$name.blocked" >"$dropins/$u.d/fleet-state-$name.conf"
  done
  systemctl daemon-reload
}

unblock() { # <entry>...
  local name u
  local -a units=()
  for name in "$@"; do
    [ -f "$records/$name.blocked" ] || continue
    mapfile -t units <"$records/$name.blocked"
    rm -f "$records/$name.blocked"
    for u in "${units[@]}"; do
      rm -f "$dropins/$u.d/fleet-state-$name.conf"
      rmdir "$dropins/$u.d" 2>/dev/null || true
    done
  done
  systemctl daemon-reload
}

# quiesce [--unmount] <entry>...: nothing uses the entries any more.  Their
# units and triggers are blocked until resume (so that no dependency, timer
# or activation starts them meanwhile), the triggers stopped, then the units
# running by then; with --unmount the entries are unmounted too.  What
# stopped on the way, whatever needed it included, is recorded for resume.
quiesce() {
  local unmount=0 name before
  if [ "$1" = --unmount ]; then
    unmount=1
    shift
  fi
  local -a units=() triggers=() running=() mounts=()
  before="$(active_units)"
  mkdir -p "$records"
  for name in "$@"; do
    mapfile -t triggers < <(triggers_of "$name")
    mapfile -t units < <(declared_units "$name")
    block "$name" "${units[@]}" "${triggers[@]}"
  done
  for name in "$@"; do
    mapfile -t -O "${#triggers[@]}" triggers < <(triggers_of "$name")
  done
  if [ "${#triggers[@]}" -gt 0 ]; then
    systemctl stop "${triggers[@]}"
  fi
  for name in "$@"; do
    mapfile -t -O "${#running[@]}" running < <(running_units_of "$name")
  done
  if [ "${#running[@]}" -gt 0 ]; then
    log "stopping ${running[*]}"
    systemctl stop "${running[@]}"
  fi
  if [ "$unmount" = 1 ]; then
    for name in "$@"; do
      mounts+=("$(mount_unit "$(field "$name" path)")")
    done
    if ! systemctl stop "${mounts[@]}"; then
      record_stopped "$before" "$@"
      resume "$@"
      die "could not unmount ${mounts[*]}"
    fi
    for name in "$@"; do
      if mountpoint -q "$(field "$name" path)"; then
        record_stopped "$before" "$@"
        resume "$@"
        die "$name: $(field "$name" path) is still mounted"
      fi
    done
  fi
  record_stopped "$before" "$@"
}

# What was active before and is not now and can be started again: units
# with a unit file (not a mount someone made by hand meanwhile), but not the
# instances an Accept=yes socket spawns (they come with a connection).
record_stopped() { # <active before> <entry>...
  local before="$1" name u
  shift
  local -a spawned=() stopped=()
  for name in "$@"; do
    while IFS= read -r u; do
      if [[ $u == *.socket ]] && [ "$(systemctl show -P Accept "$u")" = yes ]; then
        spawned+=("${u%.socket}@")
      fi
    done < <(triggers_of "$name")
  done
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    local p skip=0
    for p in "${spawned[@]}"; do
      if [[ $u == "$p"*.service ]]; then skip=1; fi
    done
    if [ "$skip" = 0 ] && [ -n "$(systemctl show -P FragmentPath "$u")" ]; then
      stopped+=("$u")
    fi
  done < <(comm -23 <(echo "$before") <(active_units))
  for name in "$@"; do
    printf '%s\n' "${stopped[@]}" >"$records/$name.stopped"
  done
}

# resume [--mounts-only] <entry>...: what quiesce stopped, started again, and
# the blocks lifted; with --mounts-only just the mounts, the rest stays
# stopped and blocked for a later resume.
resume() {
  local only=0 name
  if [ "$1" = --mounts-only ]; then
    only=1
    shift
  fi
  local -a units=()
  for name in "$@"; do
    if [ -f "$records/$name.stopped" ]; then
      mapfile -t -O "${#units[@]}" units <"$records/$name.stopped"
    fi
  done
  mapfile -t units < <(printf '%s\n' "${units[@]}" | awk 'NF && !seen[$0]++')
  if [ "$only" = 1 ]; then
    mapfile -t units < <(printf '%s\n' "${units[@]}" | grep '\.mount$' || true)
  else
    unblock "$@"
    for name in "$@"; do
      rm -f "$records/$name.stopped"
    done
  fi
  if [ "${#units[@]}" -gt 0 ]; then
    log "starting ${units[*]}"
    # a few swaps in a row would hit the mounts' start limit
    systemctl reset-failed "${units[@]}" 2>/dev/null || true
    systemctl start "${units[@]}"
  fi
}

cmd_stop() {
  [ $# -gt 0 ] || usage
  local name
  for name in "$@"; do need_entry "$name"; done
  lock
  quiesce "$@"
}

# What stop stopped; without a record of it (stop was not run, or the host
# rebooted since), the entries' triggers and their units that are not
# templates.
cmd_start() {
  [ $# -gt 0 ] || usage
  local name
  local -a units=()
  for name in "$@"; do need_entry "$name"; done
  lock
  for name in "$@"; do
    if [ ! -f "$records/$name.stopped" ]; then
      mapfile -t -O "${#units[@]}" units < <(triggers_of "$name"; declared_units "$name" | grep -v '@\.service$' || true)
    fi
  done
  resume "$@"
  if [ "${#units[@]}" -gt 0 ]; then
    systemctl start "${units[@]}"
  fi
}

# --- swapping ------------------------------------------------------------------

# swap_in [--no-start] <entry> <location>: the location becomes the entry, the
# current one (if any) is kept aside.  Nothing uses the entry meanwhile; if
# the swap fails halfway, the current one is put back.
swap_in() {
  local start=1
  if [ "$1" = --no-start ]; then
    start=0
    shift
  fi
  local name="$1" new="$2" loc aside=""
  loc="$(field "$name" location)"
  location_exists "$new" || die "no $new"

  quiesce --unmount "$name"
  if location_exists "$loc"; then
    aside="$(aside_name "$loc")"
    rename_location "$loc" "$aside"
  fi
  if ! rename_location "$new" "$loc"; then
    if [ -n "$aside" ]; then rename_location "$aside" "$loc"; fi
    resume "$name"
    die "$name: could not swap $new in; the entry is as it was"
  fi
  apply_properties "$name" "$loc"
  log "$name: swapped in${aside:+; what was there is kept aside as $aside}"

  if [ "$start" = 1 ]; then
    resume "$name"
  else
    resume --mounts-only "$name"
    log "$name: its units stay stopped (fleet-state start $name)"
  fi
  is_mounted "$name" || die "$name: $loc is not mounted at $(field "$name" path) after the swap"
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
      log "$name: replacing the snapshot $loc@$tag a run that died left"
      local m
      while IFS= read -r m; do
        if [ -n "$m" ]; then umount "$m"; fi
      done < <(findmnt -n -l -o TARGET --source "$loc@$tag" || true)
      zfs destroy "$loc@$tag"
    fi
    zfs snapshot "$loc@$tag"
    cleanups+=("zfs destroy '$loc@$tag'")
    snapdir="$scratch/snap-$name"
    mkdir -p "$snapdir"
    mount -t zfs -o ro "$loc@$tag" "$snapdir"
    cleanups+=("umount '$snapdir' && rmdir '$snapdir'")
    mountpoint -q "$snapdir" || die "$name: $loc@$tag is not mounted at $snapdir"
  else
    mount_top
    btrfs subvolume show "$top/$loc" >/dev/null 2>&1 || die "$name: no subvolume $loc"
    mkdir -p "$top/@fleet-snapshots"
    snapdir="$top/@fleet-snapshots/$name@$tag"
    if [ -e "$snapdir" ]; then
      btrfs subvolume show "$snapdir" >/dev/null 2>&1 ||
        die "$name: $snapdir is in the way and not a snapshot"
      log "$name: replacing the snapshot $snapdir a run that died left"
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
  if [ -n "$service" ]; then tags="$tags,fleet-service:$service"; fi
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
    scoped backup_entry "$name"
    [ "$scoped_rc" = 0 ] || failed+=("$name")
  done
  if [ "$all" = 1 ]; then
    # pruning goes by host, label and path, so a failed entry is no reason
    # to let the others' history grow
    local kind
    for kind in $(jq -r '.kinds[]' "$backup_json"); do
      rustic -P "$(profile "$kind")" forget --prune --no-progress
    done
    write_metrics "${#failed[@]}"
  fi
  if [ "${#failed[@]}" -gt 0 ]; then
    die "backup failed: ${failed[*]}"
  fi
}

# For monitors: when the last complete backup succeeded (kept from before
# when this one did not), and how many snapshots each repository holds, so
# that history disappearing from it is noticed although the backups
# themselves keep succeeding.
write_metrics() { # <number of failed entries>
  local metrics kind count last
  metrics="$(jq -r '.metrics // empty' "$backup_json")"
  [ -n "$metrics" ] || return 0
  install -d -m 0755 "$metrics"
  if [ "$1" = 0 ]; then
    last="fleet_backup_last_success_timestamp_seconds $(date +%s)"
  else
    last="$(grep '^fleet_backup_last_success_timestamp_seconds ' "$metrics/fleet-backup.prom" 2>/dev/null || true)"
  fi
  {
    if [ -n "$last" ]; then echo "$last"; fi
    for kind in $(jq -r '.kinds[]' "$backup_json"); do
      count="$(rustic -P "$(profile "$kind")" snapshots --json | jq '[.[].snapshots[]] | length')"
      echo "fleet_backup_snapshots{kind=\"$kind\"} $count"
    done
  } >"$metrics/fleet-backup.prom.tmp"
  mv "$metrics/fleet-backup.prom.tmp" "$metrics/fleet-backup.prom"
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

# The id of an entry's rustic snapshot: the latest of a host's (as rustic
# orders them), or the one an id (prefix) names.
find_snapshot() { # <profile> <entry> <host> <id or latest>
  local profile="$1" name="$2" from="$3" want="$4" json
  if [ "$want" = latest ]; then
    json="$(rustic -P "$profile" snapshots --json --filter-host "$from" --filter-label "$name" --filter-last 1)"
    jq -r '[.[].snapshots[]] | last | .id // empty' <<<"$json"
  else
    json="$(rustic -P "$profile" snapshots --json --filter-host "$from" --filter-label "$name")"
    case "$(jq --arg w "$want" '[.[].snapshots[] | select(.id | startswith($w))] | length' <<<"$json")" in
      0) ;;
      1) jq -r --arg w "$want" '[.[].snapshots[] | select(.id | startswith($w))][0].id' <<<"$json" ;;
      *) die "$name: '$want' names more than one snapshot" ;;
    esac
  fi
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

  local kind path loc p id incoming
  kind="$(field "$name" kind)"
  path="$(field "$name" path)"
  loc="$(field "$name" location)"
  p="$(profile "$kind")"
  [ -f "$p.toml" ] || die "$name: no repository for kind $kind"
  id="$(find_snapshot "$p" "$name" "$from" "$want")"
  [ -n "$id" ] || die "$name: no snapshot '$want' of $from (fleet-state snapshots $name)"

  lock
  # restored next to the entry, which keeps running meanwhile
  incoming="$loc.incoming"
  if location_exists "$incoming"; then
    log "$name: removing an incomplete restore ($incoming)"
    destroy_location "$incoming"
  fi
  create_location "$incoming"
  cleanups+=("destroy_if_exists '$incoming'")
  open_location "$incoming"
  log "$name: restoring snapshot ${id:0:8} of $from"
  rustic -P "$p" restore --no-progress --numeric-id "$id:$path" "$opened"
  close_location "$opened"

  if [ "$start" = 1 ]; then
    swap_in "$name" "$incoming"
  else
    swap_in --no-start "$name" "$incoming"
  fi
  log "$name: restored from ${id:0:8} (fleet-state rollback $name: back to what was there)"
}

cmd_rollback() {
  { [ $# -ge 1 ] && [ $# -le 2 ]; } || usage
  local name="$1" aside="${2:-}" loc
  need_entry "$name"
  loc="$(field "$name" location)"
  lock
  if [ -z "$aside" ]; then
    aside="$(asides_of "$loc" | tail -n 1)"
    [ -n "$aside" ] || die "$name: nothing kept aside (fleet-state list)"
  fi
  [[ $aside == "$loc.aside-"* ]] || die "$aside is not a copy of $name kept aside"
  log "$name: swapping $aside back in"
  swap_in "$name" "$aside"
}

cmd_discard() {
  [ $# = 1 ] || usage
  local aside="$1"
  [[ $aside == *.aside-* ]] || die "$aside is not a copy kept aside (fleet-state list)"
  lock
  location_exists "$aside" || die "no $aside"
  destroy_location "$aside"
  log "$aside destroyed"
}

# --- moving --------------------------------------------------------------------

tar_flags=(--xattrs --xattrs-include='*' --acls --numeric-owner --sparse)

cmd_send() {
  [ $# = 1 ] || usage
  local name="$1"
  need_entry "$name"
  [ ! -t 1 ] || die "send writes a tar stream; pipe it somewhere"
  lock
  snapshot_take "$name" fleet-send
  log "$name: sending $(du -shx "$snapdir" | cut -f1)"
  tar -C "$snapdir" -c "${tar_flags[@]}" -f - .
}

cmd_receive() {
  local name="" kind="" replace=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --replace) replace=1 ;;
      -*) usage ;;
      *)
        if [ -z "$name" ]; then
          name="$1"
        elif [ -z "$kind" ]; then
          kind="$1"
        else
          usage
        fi
        ;;
    esac
    shift
  done
  [ -n "$kind" ] || usage
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "'$name' is not an entry name"
  [ ! -t 0 ] || die "receive reads a tar stream (fleet-state send) on stdin"

  local loc incoming
  loc="$(location_of "$name" "$kind")"
  if has_entry "$name" && [ "$(field "$name" location)" != "$loc" ]; then
    die "$name is declared here as $(field "$name" location), not $loc"
  fi

  lock
  if location_exists "$loc" && [ "$replace" = 0 ]; then
    die "$loc exists on $host (--replace swaps it out and keeps it aside)"
  fi
  incoming="$loc.incoming"
  if location_exists "$incoming"; then
    log "$name: removing an incomplete receive ($incoming)"
    destroy_location "$incoming"
  fi
  create_location "$incoming"
  cleanups+=("destroy_if_exists '$incoming'")
  open_location "$incoming"
  log "$name: receiving into $loc"
  tar -C "$opened" -x "${tar_flags[@]}" --same-permissions -f -
  close_location "$opened"
  place "$name" "$incoming" "$loc"
}

# place <entry> <incoming> <location>: what was received becomes the entry's;
# if the host uses the entry already, swapped in.
place() {
  local name="$1" incoming="$2" loc="$3" aside
  if has_entry "$name" && location_exists "$loc"; then
    swap_in "$name" "$incoming"
  else
    if location_exists "$loc"; then
      aside="$(aside_name "$loc")"
      rename_location "$loc" "$aside"
      log "$name: what was there is kept aside as $aside"
    fi
    rename_location "$incoming" "$loc"
    if has_entry "$name"; then
      apply_properties "$name" "$loc"
      log "$name: received (fleet-state start $name)"
    else
      log "$name: received; in use once this host declares it"
    fi
  fi
}

set_readonly() { # <location> <on|off>
  if [ "$backend" = zfs ]; then
    if [ "$2" = on ]; then zfs set readonly=on "$1"; else zfs inherit readonly "$1"; fi
  else
    btrfs property set -ts "$top/$1" ro "$([ "$2" = on ] && echo true || echo false)"
  fi
}

# Stopped (unless stop already did), blocked and read-only, so that the copy
# a move leaves behind cannot diverge from the one moved.
cmd_freeze() {
  [ $# -gt 0 ] || usage
  local name
  local -a fresh=()
  for name in "$@"; do
    need_entry "$name"
    [ -f "$records/$name.blocked" ] || fresh+=("$name")
  done
  lock
  if [ "${#fresh[@]}" -gt 0 ]; then
    quiesce "${fresh[@]}"
  fi
  for name in "$@"; do
    set_readonly "$(field "$name" location)" on
    log "$name: frozen ($(field "$name" location) read-only, its units blocked)"
  done
}

cmd_thaw() {
  [ $# -gt 0 ] || usage
  local name
  for name in "$@"; do need_entry "$name"; done
  lock
  for name in "$@"; do
    set_readonly "$(field "$name" location)" off
  done
  resume "$@"
}

cmd_drop() {
  [ $# = 2 ] || usage
  local name="$1" kind="$2" loc m snap
  ! has_entry "$name" || die "$name is still declared on $host; drop is for what a move left behind"
  loc="$(location_of "$name" "$kind")"
  lock
  location_exists "$loc" || die "no $loc on $host"
  # unmounted wherever it is still mounted
  if [ "$backend" = zfs ]; then
    while IFS= read -r m; do
      if [ -n "$m" ]; then umount "$m"; fi
    done < <(findmnt -n -l -o TARGET --source "$loc" || true)
  else
    while IFS= read -r m; do
      if [ -n "$m" ]; then umount "$m"; fi
    done < <(findmnt -n -l -o TARGET,FSROOT | awk -v r="/$loc" '$2 == r { print $1 }')
    for snap in "$top/@fleet-snapshots/$name@"*; do
      if [ -e "$snap" ]; then btrfs subvolume delete "$snap" >/dev/null; fi
    done
  fi
  # a freeze's block, if the host has not rebooted since
  unblock "$name"
  rm -f "$records/$name.stopped"
  destroy_location "$loc"
  log "$name: $loc destroyed"
}

# --- listing -------------------------------------------------------------------

cmd_list() {
  jq -r '.entries | to_entries[] |
    "\(.key)\t\(.value.kind)\t\(.value.path)\t\(.value.location)\t\(.value.service // "-")\tbackup=\(.value.backup)"' \
    "$state_json" | column -t -s $'\t'
  local name asides
  asides="$(for name in $(jq -r '.entries | keys[]' "$state_json"); do asides_of "$(field "$name" location)"; done)"
  if [ -n "$asides" ]; then
    echo
    echo "kept aside (fleet-state rollback <entry> <aside>, fleet-state discard <aside>):"
    local -a list
    mapfile -t list <<<"$asides"
    printf '  %s\n' "${list[@]}"
  fi
}

cmd_size() {
  [ $# -gt 0 ] || usage
  local name
  for name in "$@"; do
    need_entry "$name"
    if [ "$backend" = zfs ]; then
      printf '%s\t%s\n' "$name" "$(zfs get -Hp -o value referenced "$(field "$name" location)")"
    else
      mount_top
      printf '%s\t%s\n' "$name" "$(du -sbx "$top/$(field "$name" location)" | cut -f1)"
    fi
  done
}

# --- dispatch ------------------------------------------------------------------

# btrfs: the top level once, here, so that no helper mounts it inside a
# command substitution, where its cleanup would be lost
if [ "$backend" = btrfs ]; then mount_top; fi

case "$1" in
  list) cmd_list ;;
  size) shift; cmd_size "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  start) shift; cmd_start "$@" ;;
  backup) shift; cmd_backup "$@" ;;
  init) cmd_init ;;
  snapshots) shift; cmd_snapshots "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  rollback) shift; cmd_rollback "$@" ;;
  discard) shift; cmd_discard "$@" ;;
  send) shift; cmd_send "$@" ;;
  receive) shift; cmd_receive "$@" ;;
  freeze) shift; cmd_freeze "$@" ;;
  thaw) shift; cmd_thaw "$@" ;;
  drop) shift; cmd_drop "$@" ;;
  *) usage ;;
esac
