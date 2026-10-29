# Reviewing ftl

Where the risk is, in what order to read the code, the invariants to check,
what earlier reviews found, and the known gaps. (Moved from HUMAN.md.)

## Where the risk is

The risk is concentrated in a few files:

| File | Lines | Why it matters |
|---|---|---|
| `scripts/fleet-state.sh` | ~1500 | Runs as root on every host with state. It stops services, renames and destroys datasets and subvolumes, handles credentials. |
| `scripts/fleetl.sh` | ~1200 | Orchestrates moves across two hosts with an undo list; edits `service.nix`. |
| `modules/state.nix` | ~450 | Creates and mounts entries at boot and on every switch; installs `fleet-state`; activation snippet. |
| `modules/backup.nix` | ~250 | The rustic profiles, units, timer and the data `fleet-state` reads. |
| `tests/backup.nix`, `tests/move.nix`, `tests/swap.nix` | ~1050 | What is actually proven. |

Most of the rest is evaluation-time code (lib/, module options and their
wiring), checked by the unit and flake tests; a real fleet's hosts evaluated to
identical derivations across the split of mkNixos. It can be reviewed
more quickly.

## Suggested order

1. Read `README.md` (**State**, **Backups**, **Moving a service**) for the
   promised behaviour, and `docs/architecture.md` (`scripts/` and the module
   table) for how it is built.
2. Read `modules/state.nix` and `modules/backup.nix`: what lands on a host,
   and what `/etc/fleet-state/state.json` and `backup.json` contain.
3. Read `scripts/fleet-state.sh` from the top, in this order:
   - the startup (`LC_ALL=C`, `inherit_errexit`, root check);
   - scratch space, cleanup, signals (`critical`, `uncritical`), `scoped`,
     the two locks;
   - locations (`location_of`, `create_location`, `rename_location`,
     `destroy_location`, `is_aside`);
   - units (`declared_units`, `triggers_of`, `needing`, `block`,
     `quiesce`, `resume`);
   - `swap_in` and `swap_recover`;
   - snapshots, backups, restore, rollback, discard;
   - moves (`send`, `access`, `take_access`, `receive`, `place`, `freeze`,
     `drop`).
4. Read `service_move` and `state_copy` in `scripts/fleetl.sh`, with the
   undo list in mind.
5. Read the three VM tests and compare them with what you expected from 1.

## Invariants to check

These are what the code relies on. A reviewer's job is mostly to find a path
that breaks one.

- **Nothing writes into a live entry.** Content is only written into
  `<location>.incoming`. It reaches the entry by rename, with the entry's
  units stopped, blocked and unmounted.
- **Nothing is destroyed that fleet-state did not make or was not named.**
  `destroy_location` is reached from:
  - `discard`, which takes strict `.aside-<time>` names only;
  - `drop`, which takes only frozen copies of entries the host no longer
    declares, or anything at the location with `--force`;
  - `abort`, which takes `.incoming` only;
  - the cleanups of `.incoming`.
  It never recurses into children.
- **A failed swap leaves the entry as it was, running.** `swap_recover` is
  registered before the first stop.
- **What stopped is started again, and nothing else.** Each entry records
  its own scope. A unit another stopped entry still holds is handed to that
  entry's record. Blocks are `/run` drop-ins: they are lifted by `start`, by
  a reboot, or by a deploy that no longer declares the entry. A frozen
  entry is also blocked across reboots, by a marker in
  `/var/lib/fleet-state/frozen` that its units assert absent.
- **A move is undone exactly as far as it got.**
  - Each undo is recorded before its step.
  - The target's `drop` is recorded only after `place` succeeded.
  - The source is frozen only if it stayed stopped since the stop
    (`freeze --stopped`).
- **The target never starts a moved service on empty state.** Its datasets
  exist before it is deployed.
- **Credentials handed over by `--via backup`:**
  - only plain data reaches the target: settings as JSON, plain files;
  - commands, hooks and rclone repositories are refused;
  - they live only in the run's `0700` scratch directory in `/run`;
  - rustic runs with no cache.

## What the reviews already found

Seven independent review passes ran on these commits and on a fleet's
adoption of them, the last a fresh read of the whole of it.
Every defect they reported was fixed and, where feasible, tested. The
last pass judged the work ready to push. What they found:
- **Restore** wrote into the live entry with `--delete`, wiping an entry
  mounted inside it; it now restores beside the entry and swaps it in.
- **Backups** ran entries in a subshell called as a condition, where bash
  ignores errexit: a failed snapshot went on and reported success.
  Retention overrides dropped the other periods; a switch killed a
  running backup.
- **Swaps** ended halfway on a lost connection (SIGPIPE) or a signal; they
  now hold HUP, INT and TERM, register their recovery before stopping
  anything, and lock against the state module's creation script.
- **Stop and start**: entries sharing a unit lost it on start, a blocked
  template's instances were started, and the dependency walk went through
  targets (local-fs.target reached nearly every service). Each entry now
  records only its own scope.
- **Moves**: receive placed a copy before the stream finished; undo could
  drop more than the move placed; `drop` took any location the host did
  not declare, so a mistyped host could destroy the only copy; a frozen
  copy started again after a reboot before the deploy; a lost host hung a
  move. Entry names could carry `../`.
- **`--via backup`** handed over a rustic profile, which could carry
  commands; the target now gets the table as data and writes its own.
- **The top directory's** owner and mode were lost (rustic does not keep
  them); backups tag them and restores apply them.

A fresh review is most useful where the earlier ones were weakest:
- concurrency (two runs, a deploy or reboot in the middle);
- systemd corner cases;
- the move's undo paths.

## Known limitations and untested paths

These are accepted for now, but worth a second opinion:
- **Through the admin's machine.** A streamed move passes through the
  admin's machine and its uplink. For large `data` entries use
  `--without-data` and `fleetl state copy` later.
- **Target trust in `--via backup`.** The target's root could read and
  change the source's repository (its backup history) while the restore
  runs. With per-host Storage Box sub-accounts that is the source's whole
  history.
- **Transport on the target.** `--via backup` needs `ssh` and the box's
  host key on the target, which hosts with backups have.
- **Targets in the dependency walk.** A unit that needs a stopped entry's
  unit only through a `.target` is not seen as held.
- **Old backups' top directory.** Backups made before the `fleet-root` tag
  restore with the top directory's owner and mode
  as they are on the host at the time.
- **Setup and mounts.** A mount started by hand no longer pulls in
  `fleet-state.service`; where that service failed (at boot), an entry's
  mount fails alone until it is started again (`docs/state-mounts.md`).
- **A move interrupted hard.** Undo runs from fleetl's exit trap. If the
  admin's machine dies (power, SIGKILL), nothing is undone or printed: the
  entries stay stopped and blocked on the source, `service.nix` edited,
  copies on the target. By hand: `git checkout` the `service.nix`,
  `fleet-state thaw`/`start` on the source, `abort`/`drop` on the target.
- **Agent forwarding.** `fleetl state` and `fleetl service move` run `sudo`
  through pam_rssh with the agent forwarded. Root on that host can use the
  agent meanwhile; `ssh-add -c` makes each use ask.
- **Workstations.** Every host with btrfs or ZFS gets a small, inert
  activation snippet, workstations included.
- **Not covered by a test** (a signal or a lost connection in the middle of
  a swap and `swap_recover` are covered by the `swap` VM test):
  - a signal to the whole process group in the middle of a swap (it kills
    the `systemctl stop` child too, so the step fails and `swap_recover`
    puts the entry back, exit 1);
  - a reboot between a move's stop and its freeze (`freeze --stopped`
    refuses then; the reboot after the freeze is tested);
  - a failing `--via backup` (wrong key, unknown host key);
  - an unreachable host during a move's undo (the printed recovery
    commands);
  - the real Storage Box.
  The drills in docs/testing.md cover the last one.

## Running a review with checks

To check a claim, build exactly the commit, not the working tree:

```
git -C ~/Nix/ftl archive <rev> | tar -x -C /tmp/ftl-<rev>
nix build --no-link --no-write-lock-file -L /tmp/ftl-<rev>/tests/unstable#checks.x86_64-linux.move
```

The shell scripts are packaged with `writeShellApplication`, so they run
under `set -o errexit -o nounset -o pipefail` and are built through
shellcheck. `fleet-state.sh` excludes SC2030 and SC2031 for its `scoped`
subshells. When reading them, watch for functions called as conditions
(`if f`, `f || …`), where bash turns errexit off for the whole call.

## Smartcards, AGENTS.md, access and Nix trust

- **The udev filter.** On a host with a registered reader, every other CCID
  reader becomes invisible to pcscd. That is the point, but a wrongly typed
  vendor, product, serial or port hides the user's own key. YubiKeys report
  no USB serial by default; register them by vendor and product, or `port`.
- **`trustWheel = false`.** Pushing a laptop-built closure with plain
  `nixos-rebuild --target-host` or deploy-rs fails on hosts that pick this
  up. Push through `sudo nix-daemon` first, or set `fleet.nix.trustWheel =
  true` on those hosts. Closures from the builder carry the cache signature
  and are unaffected.
- **`fleet-agents` and `fleet-sops` exist once their file does.** A fleet
  that never ran `fleetl agents sync` (or `secrets sync`) has no such check;
  once the file is committed, a stale one fails `nix flake check`.
- **Agent forwarding to every fleet host.** Root on a target can use the
  forwarded agent while the connection lasts; keys that need a touch limit
  that. `fleet.access.sshConfig.forwardAgent = false` turns it off.
- **The headless wiring** depends on nix-piv's option names (`accessGroup`,
  `sharedSocket`, `socket`, `user`, `group`, `pinCredential`). It is
  detected through `options`, so an older nix-piv without `accessGroup`
  still evaluates, with the builder on the agent's own socket.
