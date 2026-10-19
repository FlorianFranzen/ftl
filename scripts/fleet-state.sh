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
#   fleet-state send <entry> [<kind>]      the entry (a declared one, or by kind one a move
#                                          left behind), from a snapshot of it, as a tar
#                                          stream on stdout
#   fleet-state receive <entry> <kind> [--place [--replace]]
#                                          a tar stream on stdin into <location>.incoming,
#                                          for an entry this host need not declare yet;
#                                          anything tar reports fails it
#   fleet-state receive <entry> <kind> --from-backup <host> [--snapshot <id>] [--place]
#                                          the same, restored from <host>'s backup of the
#                                          entry, with access to its repository on stdin
#                                          (see access), kept in a 0700 directory in /run
#                                          for the restore and removed after
#   fleet-state place <entry> <kind> [--replace]
#                                          what receive left becomes the entry (swapped in if
#                                          the host uses it); an existing one is refused, or
#                                          with --replace kept aside
#   fleet-state abort <entry> <kind>       what receive left, removed
#   fleet-state access <kind>              the repository of a kind, as a tar stream on
#                                          stdout: its settings, the host its backups are
#                                          recorded under, the credentials they read
#   fleet-state freeze [--stopped] <entry>...
#                                          stopped, blocked and read-only: the copy left
#                                          behind cannot change any more; --stopped: only if
#                                          a stop in this boot kept it stopped all along
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
  echo "fleet-state: $*" >&2 || true
  exit 1
}

log() { echo "fleet-state: $*" >&2 || true; }

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

# --- scratch space, signals and cleanup ----------------------------------------

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
# The admin's connection going away must not end a run halfway: a write to
# it fails instead of killing (log does not care), and inside a swap HUP,
# INT and TERM are held until the entry is whole again, then end the run.
# Elsewhere they end it at once, through the cleanup.
trap '' PIPE
pending=""
uncritical() {
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ -n "$pending" ]; then exit "$pending"; fi
}
critical() {
  trap 'pending=129' HUP
  trap 'pending=130' INT
  trap 'pending=143' TERM
}
uncritical

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

# The swaps also against the state module's creation of missing locations
# (at boot and on every switch), which would otherwise make an empty one in
# the moment a location is renamed.
# Only around renames: the module's creation runs as a dependency of the
# mounts, which a swap starts.
swap_lock() {
  exec 8>/run/fleet-state.swap.lock
  flock 8
}
swap_unlock() { exec 8>&-; }

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
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "'$1' is not an entry name"
  local parent
  parent="$(jq -r --arg k "$2" '.parents[$k] // empty' "$state_json")"
  [ -n "$parent" ] || die "no kind '$2' (state or data)"
  if [ "$backend" = zfs ]; then
    echo "$pool/$parent/$1"
  else
    echo "@$parent/$1"
  fi
}

# A declared entry's location, or by kind an entry this host does not (or no
# longer) declare.
entry_location() { # <entry> [<kind>]
  if has_entry "$1"; then
    field "$1" location
  else
    [ -n "${2:-}" ] || die "$1 is not declared on $host; say its kind (state or data)"
    location_of "$1" "$2"
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

# Datasets below a dataset, subvolumes below a subvolume: not part of its
# snapshots, so neither sent nor backed up, and never destroyed with it.
has_children() { # <location>
  if [ "$backend" = zfs ]; then
    [ "$(zfs list -H -o name -r -d 1 -t filesystem,volume "$1" | wc -l)" -gt 1 ]
  else
    mount_top
    [ -n "$(btrfs subvolume list -o "$top/$1")" ]
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

# A new, empty dataset (mountpoint=legacy, POSIX ACLs and xattrs as the state
# module makes them, and the entry's properties when it is declared) or
# subvolume.
create_location() { # <location> [<entry>]
  local parent="${1%/*}"
  if [ "$backend" = zfs ]; then
    if ! zfs list -H -o name "$parent" >/dev/null 2>&1; then
      zfs create -o canmount=off -o mountpoint=none "$parent"
    fi
    local -a props=(-o mountpoint=legacy -o acltype=posixacl -o xattr=sa)
    local k v
    if [ -n "${2:-}" ] && has_entry "$2"; then
      while IFS=$'\t' read -r k v; do
        if [ -n "$k" ]; then props+=(-o "$k=$v"); fi
      done < <(jq -r --arg n "$2" '.entries[$n].zfsProperties // {} | to_entries[] | [.key, .value] | @tsv' "$state_json")
    fi
    zfs create "${props[@]}" "$1"
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
    mv -T --no-copy "$top/$1" "$top/$2"
  fi
}

# Destroys a dataset or subvolume and its snapshots, never what is below it;
# only for what fleet-state made itself or what it was asked to destroy by
# name.
destroy_location() { # <location>
  ! has_children "$1" || die "$1 has datasets or subvolumes below it; not destroying it"
  if [ "$backend" = zfs ]; then
    local snap
    while IFS= read -r snap; do
      if [ -n "$snap" ]; then zfs destroy "$snap"; fi
    done < <(zfs list -H -t snapshot -o name -d 1 "$1")
    zfs destroy "$1"
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

# Blocked units refuse to start (an assertion in a drop-in) while the entry's
# record of them exists; unblock removes both.  Blocking again adds to what
# is blocked.  The boot is recorded with it: a block does not outlive one.
block() { # <entry> <unit>...
  local name="$1" u
  shift
  local -a all=("$@")
  mkdir -p "$records"
  if [ -f "$records/$name.blocked" ]; then
    mapfile -t -O "${#all[@]}" all <"$records/$name.blocked"
  fi
  mapfile -t all < <(printf '%s\n' "${all[@]}" | awk 'NF && !seen[$0]++')
  printf '%s\n' "${all[@]}" >"$records/$name.blocked"
  if [ ! -f "$records/$name.boot" ]; then
    cat /proc/sys/kernel/random/boot_id >"$records/$name.boot"
  fi
  for u in "${all[@]}"; do
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
    rm -f "$records/$name.blocked" "$records/$name.boot"
    for u in "${units[@]}"; do
      rm -f "$dropins/$u.d/fleet-state-$name.conf"
      rmdir "$dropins/$u.d" 2>/dev/null || true
    done
  done
  systemctl daemon-reload
}

# Stopped (or frozen) since this boot, by fleet-state, and still so?
still_stopped() { # <entry>
  [ -f "$records/$1.blocked" ] && [ -f "$records/$1.boot" ] &&
    [ "$(cat "$records/$1.boot")" = "$(cat /proc/sys/kernel/random/boot_id)" ] || return 1
  local u
  while IFS= read -r u; do
    if [ -n "$u" ] && systemctl is-active --quiet "$u"; then return 1; fi
  done < <(running_units_of "$1")
}

# Units and whatever needs them, all the way up: what requires, binds to,
# is part of, requisites or is triggered by them (not through targets, which
# everything is reachable from).
needing() { # <unit>...
  local u v
  local -A seen=()
  local -a queue=("$@")
  while [ "${#queue[@]}" -gt 0 ]; do
    u="${queue[0]}"
    queue=("${queue[@]:1}")
    if [ -z "$u" ] || [ -n "${seen[$u]:-}" ]; then continue; fi
    seen[$u]=1
    case "$u" in
      *.target | *.slice | *.scope | *.device) continue ;;
    esac
    echo "$u"
    for v in $(systemctl show --value -p RequiredBy -p BoundBy -p ConsistsOf -p RequisiteOf -p TriggeredBy "$u" 2>/dev/null); do
      queue+=("$v")
    done
  done | sort -u
}

# Of a list of units on stdin, those that can be started again: with a unit
# file, and not an instance an Accept=yes socket of the entry spawns (they
# come with a connection).
restartable() { # <entry>
  local u p skip
  local -a spawned=()
  while IFS= read -r u; do
    if [[ $u == *.socket ]] && [ "$(systemctl show -P Accept "$u")" = yes ]; then
      spawned+=("${u%.socket}@")
    fi
  done < <(triggers_of "$1")
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    skip=0
    for p in "${spawned[@]}"; do
      if [[ $u == "$p"*.service ]]; then skip=1; fi
    done
    if [ "$skip" = 0 ] && [ -n "$(systemctl show -P FragmentPath "$u")" ]; then
      echo "$u"
    fi
  done
}

# add_record <entry> <file>: units added to what the entry has to start again.
add_record() {
  { cat "$2"; cat "$records/$1.stopped" 2>/dev/null || true; } |
    awk 'NF && !seen[$0]++' >"$records/$1.stopped.new"
  mv "$records/$1.stopped.new" "$records/$1.stopped"
}

# quiesce [--unmount] <entry>...: nothing uses the entries any more.  Their
# units, triggers (and with --unmount their mounts) are blocked until
# resume, so that no dependency, timer or activation starts them meanwhile;
# the triggers are stopped, then the units running by then, then the mounts
# (nested entries go along).  Each entry records what of its own scope (its
# units, triggers, mount and what needs them) stopped: at first all of it
# that is active (so that a failure halfway leaves enough to resume), at
# the end what actually stopped, both added to what was recorded before.
quiesce() {
  local unmount=0 name m
  if [ "$1" = --unmount ]; then
    unmount=1
    shift
  fi
  local -a units=() triggers=() running=() mounts=() own=()
  mkdir -p "$records"
  for name in "$@"; do
    mapfile -t own < <(triggers_of "$name"; running_units_of "$name")
    m=""
    if [ "$unmount" = 1 ]; then
      m="$(mount_unit "$(field "$name" path)")"
      mounts+=("$m")
      own+=("$m")
    fi
    mapfile -t -O "${#triggers[@]}" triggers < <(triggers_of "$name")
    needing "${own[@]}" | comm -12 <(active_units) - | restartable "$name" >"$scratch/before.$name"
    cp "$records/$name.stopped" "$scratch/prior.$name" 2>/dev/null || : >"$scratch/prior.$name"
    add_record "$name" "$scratch/before.$name"
    mapfile -t units < <(declared_units "$name"; triggers_of "$name")
    if [ -n "$m" ]; then units+=("$m"); fi
    block "$name" "${units[@]}"
  done
  if [ "${#triggers[@]}" -gt 0 ]; then
    systemctl stop "${triggers[@]}"
  fi
  # the instances running now that their sockets are stopped
  for name in "$@"; do
    mapfile -t -O "${#running[@]}" running < <(running_units_of "$name")
  done
  if [ "${#running[@]}" -gt 0 ]; then
    log "stopping ${running[*]}"
    systemctl stop "${running[@]}"
  fi
  if [ "${#mounts[@]}" -gt 0 ]; then
    if ! systemctl stop "${mounts[@]}"; then
      resume "$@"
      die "could not unmount ${mounts[*]}"
    fi
    for name in "$@"; do
      if mountpoint -q "$(field "$name" path)"; then
        resume "$@"
        die "$name: $(field "$name" path) is still mounted"
      fi
    done
  fi
  for name in "$@"; do
    cp "$scratch/prior.$name" "$records/$name.stopped"
    comm -23 <(sort "$scratch/before.$name") <(active_units) >"$scratch/stopped.$name"
    add_record "$name" "$scratch/stopped.$name"
  done
}

# resume [--mounts-only] <entry>...: what quiesce stopped, started again, and
# the blocks lifted; with --mounts-only just the mounts, the rest stays
# stopped and blocked for a later resume.  What another entry still blocks,
# or what needs that, is handed to that entry's record instead.
resume() {
  local only=0 name other u
  if [ "$1" = --mounts-only ]; then
    only=1
    shift
  fi
  local -a units=() held=()
  for name in "$@"; do
    if [ -f "$records/$name.stopped" ]; then
      mapfile -t -O "${#units[@]}" units <"$records/$name.stopped"
    fi
  done
  printf '%s\n' "${units[@]}" | awk 'NF && !seen[$0]++' >"$scratch/resume"
  if [ "$only" = 1 ]; then
    grep '\.mount$' "$scratch/resume" >"$scratch/resume.new" || true
    mv "$scratch/resume.new" "$scratch/resume"
    # the mounts are let go of now; the rest stays blocked
    for name in "$@"; do
      if [ -f "$records/$name.blocked" ]; then
        while IFS= read -r u; do
          rm -f "$dropins/$u.d/fleet-state-$name.conf"
          rmdir "$dropins/$u.d" 2>/dev/null || true
        done < <(grep '\.mount$' "$records/$name.blocked" || true)
        grep -v '\.mount$' "$records/$name.blocked" >"$records/$name.blocked.new" || true
        mv "$records/$name.blocked.new" "$records/$name.blocked"
      fi
    done
    systemctl daemon-reload
  else
    unblock "$@"
    for name in "$@"; do
      rm -f "$records/$name.stopped"
    done
  fi
  # what other entries still block waits for them
  for other in "$records"/*.blocked; do
    [ -f "$other" ] || continue
    other="$(basename "$other" .blocked)"
    mapfile -t held < "$records/$other.blocked"
    needing "${held[@]}" | comm -12 <(sort "$scratch/resume") - >"$scratch/held"
    if [ -s "$scratch/held" ]; then
      add_record "$other" "$scratch/held"
      grep -vxF -f "$scratch/held" "$scratch/resume" >"$scratch/resume.new" || true
      mv "$scratch/resume.new" "$scratch/resume"
    fi
  done
  mapfile -t units <"$scratch/resume"
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
# current one (if any) is kept aside.  Nothing uses the entry meanwhile, and
# no signal ends the swap halfway; if it fails, the current one is put back
# and what stopped started again.
swap_name="" swap_loc="" swap_aside="" swap_done=0 swap_resumed=0 swap_start=1
swap_in() {
  local start=1
  if [ "$1" = --no-start ]; then
    start=0
    shift
  fi
  local name="$1" new="$2"
  location_exists "$new" || die "no $new"
  swap_name="$name"
  swap_loc="$(field "$name" location)"
  swap_aside="" swap_done=0 swap_resumed=0 swap_start="$start"

  critical
  cleanups+=("swap_recover")
  quiesce --unmount "$name"
  swap_lock
  if location_exists "$swap_loc"; then
    swap_aside="$(aside_name "$swap_loc")"
    rename_location "$swap_loc" "$swap_aside"
    if [ "$backend" = zfs ]; then zfs set com.sun:auto-snapshot=false "$swap_aside"; fi
  fi
  rename_location "$new" "$swap_loc"
  apply_properties "$name" "$swap_loc"
  swap_done=1
  swap_unlock
  log "$name: swapped in${swap_aside:+; what was there is kept aside as $swap_aside}"

  if [ "$start" = 1 ]; then
    resume "$name"
  else
    resume --mounts-only "$name"
    log "$name: its units stay stopped (fleet-state start $name)"
  fi
  swap_resumed=1
  uncritical
  is_mounted "$name" || die "$name: $swap_loc is not mounted at $(field "$name" path) after the swap"
}

# On a failure inside a swap: the entry as it was, running again.
swap_recover() {
  if [ "$swap_done" = 0 ] && ! location_exists "$swap_loc" &&
    [ -n "$swap_aside" ] && location_exists "$swap_aside"; then
    log "$swap_name: the swap failed; putting $swap_aside back"
    swap_lock
    rename_location "$swap_aside" "$swap_loc"
  fi
  swap_unlock
  if [ "$swap_resumed" = 0 ]; then
    swap_resumed=1
    if [ "$swap_start" = 1 ]; then
      resume "$swap_name"
    else
      resume --mounts-only "$swap_name"
    fi
  fi
}

# --- snapshots -----------------------------------------------------------------

# snapshot_take <entry> <tag>: a read-only snapshot of the entry itself (not
# of whatever is mounted at its path), in $snapdir until the end of the
# process (or of the `scoped` subshell).  A snapshot left over by an earlier
# run that died is replaced.
snapdir=""
snapshot_take() { # <entry> <tag> [<location>]
  local name="$1" tag="$2" loc="${3:-}"
  [ -n "$loc" ] || loc="$(field "$name" location)"
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

  if has_children "$(field "$name" location)"; then
    log "$name: warning: the datasets or subvolumes below it are not backed up"
  fi
  snapshot_take "$name" fleet-backup
  # rustic keeps no metadata of the directory it backs up as --as-path: its
  # owner and mode go along as a tag, for the restore
  tags="$tags,fleet-root:$(stat -c '%u:%g:%a' "$snapdir")"
  log "$name: backing up $path"
  local json id
  json="$(rustic -P "$(profile "$kind")" backup --no-progress --json \
    --host "$host" --label "$name" --tag "$tags" --as-path "$path" "$snapdir")"
  id="$(jq -r '.id // empty' <<<"$json")"
  [ -n "$id" ] || die "$name: rustic reported no snapshot"
  log "$name: backed up as ${id:0:8}"
  # for whoever asked (fleetl service move restores exactly this one)
  printf '%s\t%s\n' "$name" "$id"
}

cmd_backup() {
  need_backup
  local every=0 name
  local -a names=() failed=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) every=1 ;;
      -*) usage ;;
      *) names+=("$1") ;;
    esac
    shift
  done
  if [ "$every" = 1 ]; then
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
  if [ "$every" = 1 ]; then
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
    # grouped by host and label only: an entry whose path changed is one group
    json="$(rustic -P "$profile" snapshots --json -g host,label --filter-host "$from" --filter-label "$name" --filter-last 1)"
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

# A field of a snapshot: its path, or its root's owner and mode (from the
# fleet-root tag).
snapshot_path() { # <profile> <id>
  rustic -P "$1" snapshots --json | jq -r --arg id "$2" '[.[].snapshots[] | select(.id == $id)][0].paths[0] // empty'
}

# The restored directory gets the owner and mode the entry's root had.
restore_root() { # <profile> <id> <directory>
  local root uid gid mode
  root="$(rustic -P "$1" snapshots --json |
    jq -r --arg id "$2" '[.[].snapshots[] | select(.id == $id)][0].tags // [] | map(select(startswith("fleet-root:"))) | .[0] // empty')"
  if [ -z "$root" ]; then
    log "warning: the backup does not say who owned its top directory; left root's, 0755"
    return 0
  fi
  IFS=: read -r _ uid gid mode <<<"$root"
  [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ && $mode =~ ^[0-7]{3,4}$ ]] || die "the backup's fleet-root tag is malformed: $root"
  chown "$uid:$gid" "$3"
  # five digits, so that chmod also clears set-id bits the mode does not have
  chmod "$(printf '%05d' "$((10#$mode))")" "$3"
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

  local kind loc p id incoming
  kind="$(field "$name" kind)"
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
  create_location "$incoming" "$name"
  cleanups+=("destroy_if_exists '$incoming'")
  open_location "$incoming"
  # the snapshot's own path: the entry's may have changed since
  local spath
  spath="$(snapshot_path "$p" "$id")"
  log "$name: restoring snapshot ${id:0:8} of $from ($spath)"
  rustic -P "$p" restore --no-progress --numeric-id "$id:$spath" "$opened"
  restore_root "$p" "$id" "$opened"
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
  if [[ $aside != "$loc.aside-"* ]] || ! is_aside "$aside"; then
    die "$aside is not a copy of $name kept aside"
  fi
  log "$name: swapping $aside back in"
  swap_in "$name" "$aside"
}

# A name fleet-state gave a copy it kept aside, exactly.
is_aside() { # <location>
  local stem
  if [ "$backend" = zfs ]; then stem="$pool/"; else stem="@"; fi
  [[ $1 =~ ^${stem//./\\.}(apps|data)/[A-Za-z0-9][A-Za-z0-9_-]*\.aside-[0-9]{8}T[0-9]{6}(-[0-9]+)?$ ]]
}

is_mounted_anywhere() { # <location>
  if [ "$backend" = zfs ]; then
    [ -n "$(findmnt -n -l -o TARGET --source "$1" || true)" ]
  else
    findmnt -n -l -o FSROOT | grep -qxF "/$1"
  fi
}

cmd_discard() {
  [ $# = 1 ] || usage
  local aside="$1"
  is_aside "$aside" || die "$aside is not a copy kept aside (fleet-state list)"
  lock
  location_exists "$aside" || die "no $aside"
  ! is_mounted_anywhere "$aside" || die "$aside is mounted"
  destroy_location "$aside"
  log "$aside destroyed"
}

# --- moving --------------------------------------------------------------------

tar_flags=(--xattrs --xattrs-include='*' --acls --numeric-owner --sparse)

# An entry, declared or (by kind) left behind by a move, as a tar.
cmd_send() {
  { [ $# -ge 1 ] && [ $# -le 2 ]; } || usage
  local name="$1" loc
  loc="$(entry_location "$1" "${2:-}")"
  [ ! -t 1 ] || die "send writes a tar stream; pipe it somewhere"
  lock
  location_exists "$loc" || die "no $loc on $host"
  ! has_children "$loc" || die "$name: $loc has datasets or subvolumes below it, which would not go along"
  snapshot_take "$name" fleet-send "$loc"
  log "$name: sending $(du -shx "$snapdir" | cut -f1)"
  tar -C "$snapdir" -c "${tar_flags[@]}" -f - .
}

# The repository of a kind, for a restore on another host: its settings as
# data (not a profile, which could run commands there), the host name its
# backups are recorded under, and the files it reads (password, key).  They
# pass through the pipe, and the target keeps them only for the restore; it
# can read and change the repository meanwhile, as this host can.
cmd_access() {
  [ $# = 1 ] || usage
  local kind="$1" dir name path
  need_backup
  jq -e --arg k "$kind" '.repositories | has($k)' "$backup_json" >/dev/null || die "no repository for kind $kind"
  [ ! -t 1 ] || die "access writes a tar stream with credentials; pipe it to fleet-state receive"
  dir="$scratch/access"
  mkdir -m 700 "$dir" "$dir/files"
  jq --arg k "$kind" '.repositories[$k] + { "password-file": .credentials.password }' "$backup_json" >"$dir/repository.json"
  jq '.credentials' "$backup_json" >"$dir/credentials.json"
  echo "$host" >"$dir/host"
  while IFS=$'\t' read -r name path; do
    (umask 077; cat "$path" >"$dir/files/$name")
  done < <(jq -r '.credentials | to_entries[] | [.key, .value] | @tsv' "$backup_json")
  log "access to the $kind repository of $host"
  tar -C "$dir" -c -f - .
}

# The access on stdin unpacked into a private directory and checked (plain
# files only, no commands or hooks, no credential path left that is not
# pointed into it), the profile written from it; its path (without .toml) in
# $access_profile, the source's host name in $access_host.  rustic keeps no
# cache of the foreign repository.
access_profile="" access_host=""
take_access() {
  local dir="$scratch/access" name path json
  mkdir -m 700 "$dir"
  tar -C "$dir" -x --no-same-owner --no-same-permissions -f -
  if [ -n "$(find "$dir" -mindepth 1 ! -type f ! -type d)" ]; then
    die "the access holds more than files"
  fi
  [ -f "$dir/repository.json" ] && [ -f "$dir/credentials.json" ] && [ -f "$dir/host" ] ||
    die "no repository access on stdin (fleet-state access)"
  access_host="$(head -n 1 "$dir/host")"
  [[ $access_host =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "the access names no host"
  json="$(cat "$dir/repository.json")"
  jq -e '[paths | map(tostring) | .[] | test("command|hook"; "i")] | any | not' <<<"$json" >/dev/null ||
    die "the repository settings carry commands or hooks; not using them"
  # a local path, OpenDAL or a REST server; not rclone, which can run commands
  jq -e '.repository | type == "string" and test("^(/|opendal:|rest:)")' <<<"$json" >/dev/null ||
    die "the repository is of a kind fleet-state does not hand to another host"
  jq -e '[.. | select(. == null)] | length == 0' <<<"$json" >/dev/null || die "the repository settings hold nulls"
  while IFS=$'\t' read -r name path; do
    [[ $name =~ ^[A-Za-z0-9_-]+$ ]] && [ -f "$dir/files/$name" ] || die "the access lacks $name"
    json="$(jq --arg p "$path" --arg n "$dir/files/$name" 'walk(if . == $p then $n else . end)' <<<"$json")"
  done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' "$dir/credentials.json")
  while IFS= read -r path; do
    if [ -n "$path" ] && grep -qF -- "$path" <<<"$json"; then
      die "the repository settings use $path other than as a whole value; not guessing"
    fi
  done < <(jq -r '.[]' "$dir/credentials.json")
  chmod -R go= "$dir"
  jq -r '
    def scalar: type != "object";
    "[repository]",
    (to_entries[] | select(.value | scalar) | "\(.key | tojson) = \(.value | tojson)"),
    (to_entries[] | select(.value | scalar | not) |
      "[repository.\(.key | tojson)]",
      (.value | to_entries[] |
        if (.value | scalar) then "\(.key | tojson) = \(.value | tojson)"
        else error("nested too deep: \(.key)") end))' <<<"$json" >"$dir/profile.toml" ||
    die "the repository settings are not a flat table"
  export RUSTIC_NO_CACHE=true
  access_profile="$dir/profile"
}

cmd_receive() {
  local name="" kind="" replace=0 from="" want=latest now=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --replace) replace=1 ;;
      --place) now=1 ;;
      --from-backup) from="${2:?--from-backup needs a host}"; shift ;;
      --snapshot) want="${2:?--snapshot needs an id}"; shift ;;
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
  [ ! -t 0 ] || die "receive reads a tar stream (fleet-state send or access) on stdin"
  [ -n "$from" ] || [ "$want" = latest ] || die "--snapshot goes with --from-backup"

  local loc incoming id="" spath=""
  loc="$(location_of "$name" "$kind")"
  if has_entry "$name" && [ "$(field "$name" location)" != "$loc" ]; then
    die "$name is declared here as $(field "$name" location), not $loc"
  fi

  lock
  if location_exists "$loc" && [ "$replace" = 0 ]; then
    die "$loc exists on $host (--replace swaps it out and keeps it aside)"
  fi
  if [ -n "$from" ]; then
    take_access
    if [ "$access_host" != "$from" ]; then
      log "$name: $from records its backups as $access_host"
    fi
    id="$(find_snapshot "$access_profile" "$name" "$access_host" "$want")"
    [ -n "$id" ] || die "$name: no backup '$want' of $access_host in that repository"
    spath="$(snapshot_path "$access_profile" "$id")"
  fi
  incoming="$loc.incoming"
  if location_exists "$incoming"; then
    log "$name: removing an incomplete receive ($incoming)"
    destroy_location "$incoming"
  fi
  create_location "$incoming" "$name"
  # read by the cleanup below
  # shellcheck disable=SC2034
  keep_incoming=0
  cleanups+=("[ \"\$keep_incoming\" = 1 ] || destroy_if_exists '$incoming'")
  open_location "$incoming"
  if [ -n "$from" ]; then
    log "$name: restoring ${id:0:8}, $from's backup of $spath"
    rustic -P "$access_profile" restore --no-progress --numeric-id "$id:$spath" "$opened"
    restore_root "$access_profile" "$id" "$opened"
  else
    log "$name: receiving"
    # tar only warns about what it could not set (ACLs, xattrs): that is a
    # failure here, as is anything else it has to say
    if ! tar -C "$opened" -x "${tar_flags[@]}" --same-permissions -f - 2>"$scratch/tar.err" ||
      [ -s "$scratch/tar.err" ]; then
      cat "$scratch/tar.err" >&2 || true
      die "$name: the stream did not arrive whole; nothing kept"
    fi
  fi
  close_location "$opened"
  if [ "$now" = 1 ]; then
    place "$name" "$incoming" "$loc" "$replace"
  else
    # shellcheck disable=SC2034
    keep_incoming=1
    log "$name: received into $incoming (fleet-state place $name $kind, or abort)"
  fi
}

# place <entry> <kind> [--replace]: what receive left in <location>.incoming
# becomes the entry's.
cmd_place() {
  local name="" kind="" replace=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --replace) replace=1 ;;
      -*) usage ;;
      *) if [ -z "$name" ]; then name="$1"; elif [ -z "$kind" ]; then kind="$1"; else usage; fi ;;
    esac
    shift
  done
  [ -n "$kind" ] || usage
  local loc
  loc="$(location_of "$name" "$kind")"
  lock
  location_exists "$loc.incoming" || die "nothing received for $name ($loc.incoming)"
  place "$name" "$loc.incoming" "$loc" "$replace"
}

# abort <entry> <kind>: what receive left, gone; never the entry itself.
cmd_abort() {
  [ $# = 2 ] || usage
  local loc
  loc="$(location_of "$1" "$2")"
  lock
  destroy_if_exists "$loc.incoming"
}

# place <entry> <incoming> <location> <replace>: what was received becomes
# the entry's; if the host uses the entry already, swapped in.
place() {
  local name="$1" incoming="$2" loc="$3" replace="$4" aside
  if location_exists "$loc" && [ "$replace" = 0 ]; then
    die "$loc exists on $host (--replace swaps it out and keeps it aside)"
  fi
  if has_entry "$name" && location_exists "$loc"; then
    swap_in "$name" "$incoming"
  else
    swap_lock
    critical
    aside=""
    if location_exists "$loc"; then
      aside="$(aside_name "$loc")"
      rename_location "$loc" "$aside"
      log "$name: what was there is kept aside as $aside"
    fi
    if ! rename_location "$incoming" "$loc"; then
      if [ -n "$aside" ]; then rename_location "$aside" "$loc"; fi
      swap_unlock
      uncritical
      die "$name: could not put $incoming in place; left as it was"
    fi
    swap_unlock
    uncritical
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
# a move leaves behind cannot diverge from the one moved.  --stopped: only if
# a stop in this boot left them stopped all along (a move freezes what it
# sent, not what ran again meanwhile).
cmd_freeze() {
  local only_stopped=0
  if [ "${1:-}" = --stopped ]; then
    only_stopped=1
    shift
  fi
  [ $# -gt 0 ] || usage
  local name
  local -a fresh=()
  for name in "$@"; do
    need_entry "$name"
    if [ "$only_stopped" = 1 ]; then
      still_stopped "$name" || die "$name has run again since it was stopped (a reboot, a start); not freezing it"
    fi
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
  ! has_entry "$name" || die "$name is still declared on $host; drop what a move left once the host is deployed without it"
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
  destroy_location "$loc"
  # a freeze's block, if the host has not rebooted since
  unblock "$name"
  rm -f "$records/$name.stopped"
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
  place) shift; cmd_place "$@" ;;
  abort) shift; cmd_abort "$@" ;;
  access) shift; cmd_access "$@" ;;
  receive) shift; cmd_receive "$@" ;;
  freeze) shift; cmd_freeze "$@" ;;
  thaw) shift; cmd_thaw "$@" ;;
  drop) shift; cmd_drop "$@" ;;
  *) usage ;;
esac
