# Handover

This is for whoever takes over ftl and the fleets built on it. It covers
how to test the software, what is left to do before and after the next
deploy, and how to review the code that has not been pushed yet.

State as of 2026-10-22. Check `git status -sb` in each repository before
relying on anything below.

## The three repositories

| Repository | Path | Branch | Unpushed | What it is |
|---|---|---|---|---|
| ftl | `~/Nix/ftl` | `main` | 15 commits (the 13 below, this file, and the fixes of the last review) | The library: `ftl.lib.mkFlake`, the NixOS modules, `fleetl`, `fleet-state`, the test suites. |
| infra | `~/Denkmuskel/infra` | `main` | 56 commits | The server fleet (amphi, baro, darwin, turing) built with ftl. |
| nixrc | `/etc/nixos` | `master` | 2 commits | The workstations built with ftl. |

Both consumers lock ftl at a commit that exists only in the local ftl
checkout (`jq -r .nodes.ftl.locked.rev flake.lock` names it), so **ftl
must be pushed before infra or nixrc**. Otherwise
nothing that reads those locks can fetch ftl (comin on the hosts, a fresh
clone, CI).

Commits are made unsigned and signed when pushed. ftl and infra use a
`scope: sentence` subject and a prose body. nixrc uses short imperative
subjects without a body.

## What the unpushed ftl work does

The 13 commits, oldest first:

| Commit | Subject | In short |
|---|---|---|
| `59d0958` | fleetl: secrets sync re-keys the stores whose recipients differ | `secrets sync` compares each store's recipients (sops keeps them in the clear) with its rule. |
| `51aae67` | fleet: the aliases of the rename are gone | The `ftl.*` option mirror, `ftlPeers`, `ftlManifest`, `peers` and the old layer kinds are removed. |
| `1f71383` | lib: mkNixos is split by entity under lib/nixos | `lib/nixos.nix` now only assembles; hosts, services, users, sops, generators and layers live under `lib/nixos/`. |
| `1e8588e` | fleetl: host exec runs a command on one host or on all | Runs a command over ssh, pinned to the host's `ssh.pub`. |
| `077a1e5` | generators: fleet-wide ones, and inputs from other generators | `scope = "fleet"` and `inputs = [ "<gen>/<file>" ]`. |
| `4a7009a` | backup: fleet.backup puts fleet.state into rustic, through fleet-state | The new `modules/backup.nix` and the host tool `scripts/fleet-state.sh`. |
| `5567e80` | state: restore an entry in place, from the admin's machine too | First restore, and `fleetl state …`. |
| `35ba05f` | state: restores swap a fresh copy in | Restore rebuilt around "write beside, then swap". |
| `723d1ff` | fleetl: service move takes a service and its state to another host | `fleetl service move`, streaming. |
| `acdb4d4` | fleetl: service move --via backup | The target restores from the source's repository. |
| `0908bd6` | state: what the reviews … found | The largest fix round. |
| `487cea7` | state: per-entry scopes for stop and start | Fix round. |
| `5c7d10e` | state: blocked templates hold their instances | Last fix round. |

The user-facing description is in `README.md`, under **State**, **Backups**
and **Moving a service**, and in the `fleetl` command list. The map of the
code is in `docs/architecture.md`, under `modules/` and `scripts/`.

In infra, `99c1d01` moves the Storage Box backups onto ftl's `fleet.backup`
and bumps the ftl lock. In nixrc, `39e1fcd` only bumps the lock.

## Testing

### Prerequisites

- **Nix:** flakes enabled. The suites were run with Nix 2.34.
- **VM tests:** KVM, a few GB of RAM per test, and disk for the VM images.
  The `move` test runs four VMs at once.
- **Time:** a full suite took tens of minutes on a 32-core machine. Single
  checks take one to five minutes.

### The ftl suites

The tests live in `tests/`. `tests/default.nix` defines the checks. Two
flakes run them, `tests/stable` and `tests/unstable`, each pinning nixpkgs,
home-manager, sops-nix, comin and deploy-rs of its channel, with ftl as a
relative input. The working tree is tested; uncommitted files must be known
to git (`git add -N`).

Everything, both channels:

```
cd ~/Nix/ftl
nix flake check -L --no-write-lock-file ./tests/unstable
nix flake check -L --no-write-lock-file ./tests/stable
```

One check:

```
nix build --no-link --no-write-lock-file -L ./tests/unstable#checks.x86_64-linux.<name>
```

| Check | Kind | Covers |
|---|---|---|
| `unit-loader`, `unit-static`, `unit-packages`, `unit-home`, `unit-nixos`, `unit-users`, `unit-deploy` | evaluation | Each `mk*` function on `tests/fixtures/layout`. `unit-nixos` includes stores, generators (scopes, inputs, cycles) and services. |
| `flake-isolated`, `flake-full` | evaluation | `mkFlake` with one family at a time, and with all of them. |
| `cli` | build | `fleetl` on stubs: `.sops.yaml` rendering, `host exec`, `state …` commands, fleet and host generators end to end. |
| `generators` | build | Each generator writes exactly the files it declares; a certificate signed by the fixture's CA. |
| `modules` | VM | A host with every ftl module enabled. |
| `state-btrfs`, `state-zfs` | VM | `fleet.state` on an empty disk: boot without the filesystem, then creation and mounts. |
| `backup-btrfs`, `backup-zfs` | VM | See below. |
| `move` | VM, 4 nodes | See below. |
| `layers`, `pipeline`, `pipeline-agent`, `cache` | VM | Layers and the update pipeline (older, unchanged by this work). |
| `services` | VM | sops-nix decrypting with the SSH host key. |

The backup tests (`tests/backup.nix`) cover:
- backup and init, labels and tags, metrics, leftover snapshots;
- restore by swap, rollback and discard;
- an entry nested inside another;
- dependents, timers and template sockets stopped and restarted;
- repeated and shared stops;
- `freeze --stopped`;
- refused repository accesses;
- the top directory's owner and mode, including a backup made without the
  tags, as all of infra's are so far;
- an entry with a dataset below it.

The move test (`tests/move.nix`) runs an admin machine (fleetl with a
stubbed `nix eval`, but real ssh), a btrfs source, a ZFS target and an sftp
"storage box". It covers:
- refusals;
- a failed move undone without touching what was in the way;
- a streamed move;
- a move `--via backup`;
- both hosts switched to the moved configuration, with the target running
  the service on the received state;
- the source's frozen copies dropped.

If a VM test fails, `nix log <drv>` has the whole run. Searching it for `!!!`
finds the failing subtest.

### infra's own checks

infra has its own VM tests in `tests/`, including `backup-btrfs` and
`backup-zfs`. These run the real Storage Box module against an sshd on
port 23 playing the box. There is also the `fleet-sops` check:

```
cd ~/Denkmuskel/infra
nix build --no-link -L .#checks.x86_64-linux.backup-btrfs .#checks.x86_64-linux.backup-zfs .#checks.x86_64-linux.fleet-sops
```

To try an infra change against a local, unpushed ftl, add
`--override-input ftl path:/home/florian/Nix/ftl` (or
`git+file:///home/florian/Nix/ftl?rev=<rev>` for an exact commit). The same
works for `nix run .#fleetl -- …`.

To compare a host before and after a change without touching the working
tree, evaluate both versions of ftl and diff them:

```
a=$(nix eval --raw .#nixosConfigurations.darwin.config.system.build.toplevel.drvPath)
b=$(nix eval --raw --override-input ftl path:/home/florian/Nix/ftl .#nixosConfigurations.darwin.config.system.build.toplevel.drvPath)
nix run nixpkgs#nix-diff -- "$a" "$b"
```

Do not `git stash` in these repositories to get a "before" state. They are
worked on in parallel.

### Drills on the real hosts, after the deploy

The VM tests do not touch the real Storage Box or real services, and they
reboot only once (a source between its freeze and its deploy). Before trusting restores and moves with
anything that matters, run these once.

1. **A backup.** On any host:
   - `sudo systemctl start fleet-backup`, then `sudo fleet-state snapshots`.
   - The new snapshots carry `fleet-entry:`, `fleet-service:` and
     `fleet-root:` tags.
   - `/var/lib/prometheus-node-exporter-text-files/fleet-backup.prom` exists.
   - The alerts `BackupOverdue` and `BackupMissing` stay quiet.
2. **A restore of something cheap.** For example `ntfy` or `alertmanager` on
   amphi:
   - `fleetl state restore amphi ntfy`; the service comes back on its own.
   - `fleetl state list amphi` shows the copy kept aside.
   - `fleetl state rollback amphi ntfy` swaps it back.
   - `fleetl state discard amphi <aside>` removes it.
3. **A move of a throwaway service.** Do not start with a real service.
   - Add a small service (one state entry, one unit, a fixed uid) to two
     hosts' reach, and give it some data.
   - `fleetl service move <svc> <host>`, commit, deploy the target, then
     the source.
   - Check the data on the target, then `fleetl state drop <source> <entry> <kind>`
     (data left behind with `--without-data` needs `--force`).
   - Repeat with `--via backup`.

## Remaining steps

In order:

1. **Review the unpushed ftl work.** See the next section.
2. **Push ftl** to `main`, signing on push.
3. **Re-key infra's host stores.** This is still outstanding. The check
   reports four host stores whose recipients differ from their rules:

   ```
   cd ~/Denkmuskel/infra
   nix run .#fleetl -- secrets sync          # needs the OpenPGP card
   nix run .#fleetl -- secrets sync --check  # must report nothing
   ```

   Commit the re-keyed `nixos/hosts/*/secrets.yaml` files.
4. **Push infra and nixrc.**
5. **Deploy infra.**
   - Avoid 00:00–01:00, the backup window.
   - The backup units are renamed from `infra-backup` to `fleet-backup`, the
     metrics from `infra_backup_*` to `fleet_backup_*`, and the alert rules
     follow. The old `infra-backup.prom` is removed on switch.
   - The first `fleet-backup` runs within a day, inside the 30 h of
     `BackupMissing`.
6. **On each host, once it decrypts with its SSH host key:** remove the old
   age key, `sudo rm /var/lib/sops-nix/key.txt`. This step is left over
   from the move to SSH host keys.
7. **Clean up what the old backup module left.**
   - amphi, baro (btrfs): an empty `@infra-backup` directory at the top
     level of the filesystem, and any subvolume a killed run left in it.
     Mount with `subvolid=5` to see it.
   - darwin, turing (ZFS): any `<dataset>@infra-backup` snapshots
     (`zfs list -t snapshot | grep infra-backup`).
8. **Run the drills above.**

Optional, not started:
- `fleetl` has no `state init`; repositories are created with
  `sudo fleet-state init` or `sudo systemctl start fleet-backup-init`.
- Real fleet-scoped generators in infra (a CA, a shared PSK); the mechanism
  exists, nothing uses it yet.

## Reviewing the code

### Where the risk is

About 5,000 lines changed across 46 files, but the risk is concentrated:

| File | Lines | Why it matters |
|---|---|---|
| `scripts/fleet-state.sh` | ~1450 | Runs as root on every host with state. It stops services, renames and destroys datasets and subvolumes, handles credentials. |
| `scripts/fleetl.sh` | ~1000 | Orchestrates moves across two hosts with an undo list; edits `service.nix`. |
| `modules/state.nix` | ~450 | Creates and mounts entries at boot and on every switch; installs `fleet-state`; activation snippet. |
| `modules/backup.nix` | ~250 | The rustic profiles, units, timer and the data `fleet-state` reads. |
| `tests/backup.nix`, `tests/move.nix` | ~840 | What is actually proven. |

The earlier commits (`59d0958` to `077a1e5`) touch evaluation-time code
only. Their output is checked by the unit and flake tests, and infra's
hosts evaluated to identical derivations across the split. They can be
reviewed quickly.

### Suggested order

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
5. Read the two VM tests and compare them with what you expected from 1.

### Invariants to check

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

### What the reviews already found

Seven independent review passes ran on these commits and on infra's
adoption, the last on a different model (Fable) over the whole of it.
Every defect they reported was fixed and, where feasible, tested; the
commit messages of `35ba05f`, `0908bd6`, `487cea7`, `5c7d10e` and the
latest one (the Fable fixes) list them. The last pass judged the work ready to
push; what it found (`drop` taking any undeclared location, undo needing
the host that failed, frozen copies starting again after a reboot, and
smaller ones) is fixed in that last commit. A fresh review is most useful where the earlier ones were weakest:
- concurrency (two runs, a deploy or reboot in the middle);
- systemd corner cases;
- the move's undo paths.

### Known limitations and untested paths

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
  (all of infra's so far) restore with the top directory's owner and mode
  as they are on the host at the time.
- **Agent forwarding.** `fleetl state` and `fleetl service move` run `sudo`
  through pam_rssh with the agent forwarded. Root on that host can use the
  agent meanwhile; `ssh-add -c` makes each use ask.
- **Workstations.** Every host with btrfs or ZFS gets a small, inert
  activation snippet, nixrc's workstations included.
- **Not covered by a test:**
  - a signal or a lost connection in the middle of a swap;
  - `swap_recover` itself;
  - a reboot between a move's stop and its freeze (`freeze --stopped`
    refuses then; the reboot after the freeze is tested);
  - a failing `--via backup` (wrong key, unknown host key);
  - an unreachable host during a move's undo (the printed recovery
    commands);
  - the real Storage Box.
  The drills above cover the last one.

### Running a review with checks

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
