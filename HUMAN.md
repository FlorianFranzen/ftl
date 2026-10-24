# Handover

This is for whoever takes over ftl and the fleets built on it. It covers
how to test the software, what is left to do before and after the next
deploy, and how to review the backup, restore and move work.

State as of 2026-10-25. `git log --oneline @{u}..` in each repository shows
what is not pushed; check it before relying on anything below. Two
workstations hold clones of the three repositories, so a commit named
here may exist on only one of them until it is pushed.

infra's host stores are re-keyed for the hosts' SSH host keys (infra
`5607cec`, pushed); `nix run .#fleetl -- secrets sync --check` in infra
reports every store matching its rule. Run it again before any deploy: a
host whose store does not list its SSH host key cannot decrypt its
secrets, since infra's configuration no longer uses the old age keys.

## The three repositories

| Repository | Path | Branch | What it is |
|---|---|---|---|
| ftl | `~/Nix/ftl` | `main` | The library: `ftl.lib.mkFlake`, the NixOS modules, `fleetl`, `fleet-state`, the test suites. |
| infra | `~/Denkmuskel/infra` | `main` | The server fleet (amphi, baro, darwin, turing) built with ftl. |
| nixrc | `/etc/nixos` | `master` | The workstations built with ftl. |

The backup, restore and move work in ftl, and infra's adoption of it, was
pushed on 2026-10-22, up to ftl `198b0f3` and infra `8e5eedf`; infra's
re-keying (`5607cec`) followed, and ftl is pushed up to `54f1828`. Not
pushed as of this writing:
- ftl: the smartcard and AGENTS.md work and what followed it (the last
  section of this file), on the workstation it was written on;
- infra: TLS between the hosts (`674e33a`) and two lock bumps to ftl
  `54f1828`, unpushed on the other workstation;
- nixrc: lock bumps to ftl `54f1828`, unpushed on the other workstation.

Both consumers lock ftl by revision (`jq -r .nodes.ftl.locked.rev
flake.lock`), so **ftl must always be pushed before them**. Otherwise
nothing that reads those locks can fetch ftl (comin, a fresh clone, CI).

Commits were made unsigned, meant to be signed when pushed. The commits
pushed so far carry no signature (`git log --format='%h %G?'` shows `N`).
If signing on push meant `git push --signed`, that leaves nothing on the
commits; if it meant signed commits, that is still to decide, for what is
pushed and for what is not.

ftl and infra use a `scope: sentence` subject and a prose body. nixrc uses
short imperative subjects without a body.

## What the ftl work does

The commits, oldest first (`git log --oneline 59d0958^..` in ftl):

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
| `5c7d10e` | state: blocked templates hold their instances | Fix round. |
| `08428ae` | docs: HUMAN.md | This file. |
| `198b0f3` | state: what the last review found | Fixes of the last review: `drop` only takes frozen copies, freezes survive reboots, undo prints what it could not do. |
| `f5a0df5` | state: mount units name nothing but the storage | The fix in `docs/state-mounts.md`. |
| `863ce07` | docs: HUMAN.md after the re-keying | This file. |
| `f06f4e8` | fleetl: secrets move, state init, and generators for a fleet CA | `fleetl secrets move`, `fleetl state init`, the `fleet-ca` and `host-tls` generators. |
| `32014f5` | lib: a PEM key file is read whole | Certificates next to `host.nix` keep every PEM line. |
| `13fcd7f` | generators: the host's metadata, and host-tls names what it lists | Generators get `HOST_JSON`; `host-tls` takes its names from `tls.addresses`. |
| `f7b9e98` | docs: HUMAN.md, the steps the fleet CA and the monitor secrets need | This file. |
| `54f1828` | state: a receive takes timestamps from a clock a little ahead | Fix in `fleet-state receive`. |
| `567fb4f` | smartcard: readers registered in the metadata, AGENTS.md generated from it | See the last section. |

The user-facing description is in `README.md`, under **State**, **Backups**
and **Moving a service**, and in the `fleetl` command list. The map of the
code is in `docs/architecture.md`, under `modules/` and `scripts/`.

In infra, `99c1d01` moves the Storage Box backups onto ftl's `fleet.backup`;
the later infra and nixrc commits named `flake: …ftl…` only bump the lock
(infra's last one also runs the setup service in its backup test).

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
| `generators` | build | Each generator, ftl's own (`host-keys`, `age-key`, `fleet-ca`, `host-tls`) and the fixture's, writes exactly the files it declares; the certificates verify against their CA. |
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

1. **Push ftl first, then infra and nixrc.** The consumers' locks name
   ftl's last commit, which must be fetchable before they are. Decide on
   signatures first (see above).
2. **Check that every store still matches its rule** (it did when this was
   written):

   ```
   cd ~/Denkmuskel/infra
   nix run .#fleetl -- secrets sync --check  # must report nothing
   ```

   If it reports a store, `nix run .#fleetl -- secrets sync` (needs the
   OpenPGP card) and commit the re-keyed files before deploying.
3. **Check what holds the mounts, on each host, right before its deploy.**
   The decoupling of the mounts rewrites every mount unit once, so this
   one deploy unmounts every state entry on the host; anything holding one
   (a shell's working directory, a script, a backup walk) fails the deploy,
   which then rolls back. This is what failed darwin's deploy on
   2026-10-22. `docs/state-mounts.md` has the checks:

   ```
   tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_path}' | grep -e /srv -e /var/lib
   sudo fuser -vm /srv/media     # and each entry's path (fleet-state list)
   ```

   After this deploy a mount unit changes only when its storage does.
4. **Deploy infra.**
   - Avoid 00:00–01:00, the backup window.
   - The backup units are renamed from `infra-backup` to `fleet-backup`, the
     metrics from `infra_backup_*` to `fleet_backup_*`, and the alert rules
     follow. The old `infra-backup.prom` is removed on switch.
   - While an entry is stopped or frozen, a deploy reports its units as
     failed; that is by design (see the README).
5. **Watch the first backup.** It runs within a day of the deploy, inside
   the 30 h of `BackupMissing`. On each host: `systemctl status
   fleet-backup`, `sudo fleet-state snapshots` (the new snapshots carry
   `fleet-entry:`, `fleet-service:` and `fleet-root:` tags), and
   `/var/lib/prometheus-node-exporter-text-files/fleet-backup.prom`. The
   alerts `BackupOverdue` and `BackupMissing` stay quiet.
6. **Remove the old age key on each host**, once it runs the new
   configuration and its secrets are in place (`ls /run/secrets`):
   `sudo rm /var/lib/sops-nix/key.txt`. Nothing reads it any more.
7. **Clean up what the old backup module left.**
   - amphi, baro (btrfs): an empty `@infra-backup` directory at the top
     level of the filesystem, and any subvolume a killed run left in it.
     Mount with `subvolid=5` to see it.
   - darwin, turing (ZFS): any `<dataset>@infra-backup` snapshots
     (`zfs list -t snapshot | grep infra-backup`).
8. **Run the drills above**: a backup, a restore with rollback on a cheap
   entry, and a move of a throwaway service, streamed and `--via backup`.

Prepared, waiting for a session with the OpenPGP card (both decrypt or
write existing stores):

9. **Switch on TLS between the hosts** (infra `674e33a`, `nixos/modules/mesh-tls.nix`).
   The code is deployed off; with it on, metrics and logs between the hosts
   need a certificate of the fleet's own CA. In infra:

   ```
   nix run .#fleetl -- host generate amphi host-tls   # makes the CA first (nixos/fleet-ca.pub)
   nix run .#fleetl -- host generate baro host-tls
   nix run .#fleetl -- host generate darwin host-tls
   nix run .#fleetl -- host generate turing host-tls
   nix run .#fleetl -- secrets sync --check
   ```

   Commit `nixos/fleet-ca.pub`, `nixos/identity.yaml`, each host's `tls.pub`
   and `secrets.yaml`, then set `infra.meshTls.enable = true;` for every
   host (in `nixos/modules/defaults.nix`) and deploy all four in one go: a
   monitor scraping over TLS a host not yet serving it sees it as down until
   that host is deployed too. The test `mesh-tls` in infra shows the whole
   path working.
10. **Move the monitor pair's shared secrets into the monitor's store.**
    amphi and baro each hold `deadman/url`, `grafana/*` and `ntfy/*`; what
    both hold alike belongs in `nixos/services/monitor/secrets.yaml`.
    `dkim/key` stays per host (each monitor signs with its own selector).
    In infra, one key at a time, so that a key the two hold differently
    stays where it is:

    ```
    for k in deadman/url grafana/admin-password grafana/secret-key ntfy/env ntfy/alertmanager-token; do
      nix run .#fleetl -- secrets move --to nixos/services/monitor/secrets.yaml \
        --from nixos/hosts/amphi/secrets.yaml --from nixos/hosts/baro/secrets.yaml "$k" ||
        echo "$k stays per host"
    done
    ```

    Then, in `nixos/services/monitor/monitor.nix`, give each moved key
    `sopsFile = service.sopsFile;`, and commit the code and the three stores
    together (sops-nix checks at build time that a key is where the module
    says). Deploy amphi and baro.

Done since: `fleetl state init <host>` creates a host's backup repositories
from the admin's machine.

## Reviewing the code

### Where the risk is

About 5,000 lines changed across 46 files, but the risk is concentrated:

| File | Lines | Why it matters |
|---|---|---|
| `scripts/fleet-state.sh` | ~1500 | Runs as root on every host with state. It stops services, renames and destroys datasets and subvolumes, handles credentials. |
| `scripts/fleetl.sh` | ~1200 | Orchestrates moves across two hosts with an undo list; edits `service.nix`. |
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
adoption, the last a fresh read of the whole of it.
Every defect they reported was fixed and, where feasible, tested; the
commit messages of `35ba05f`, `0908bd6`, `487cea7`, `5c7d10e` and the
latest one (the last fixes) list them. The last pass judged the work ready to
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
- **Setup and mounts.** A mount started by hand no longer pulls in
  `fleet-state.service`; where that service failed (at boot), an entry's
  mount fails alone until it is started again (`docs/state-mounts.md`).
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

## Smartcards, AGENTS.md, ssh and Nix trust (2026-10-24)

`567fb4f`, `smartcard: readers registered in the metadata, AGENTS.md
generated from it`, and the milestones that follow it (see "Milestones"
below). It also touches access, client and mkDeploy. Two sibling
repositories go with it:

| Repository | Path | Branch | State |
|---|---|---|---|
| nix-piv | `~/Nix/nix-piv` | `main` | `services.piv-agent.accessGroup` added, see its `HUMAN.md`; published on GitHub. |
| deploy-rs (clone of serokell's) | `~/Nix/deploy-rs` | `sudo-copy` | `sudoCopy` implemented and tested; not committed, not proposed upstream yet. |

### What it does

| Piece | Where | In short |
|---|---|---|
| Reader registration | `lib/nixos/smartcards.nix` (the vocabulary in `lib/smartcard.nix`), `smartcard` in host.nix, mkFlake's `smartcard` | Readers by USB vendor, product, serial or port, for every host or one; `presence` is `attended` or `headless`. Validated eagerly; `fleet.hosts.<h>.smartcard`. |
| `fleet.smartcard` | `modules/smartcard.nix` | On only when a reader is registered. pcscd is bound to exactly those readers: a udev rule sets `PCSCLITE_IGNORE=1` on every USB device and `0` on the registered ones (pcscd has no allow-list). scdaemon through pcscd (`disable-ccid`). Attended: yubikey-touch-detector. Headless: nix-piv's `piv-agent`, its group socket, the builder joined to it. |
| AGENTS.md | `lib/agents.nix`, `modules/agents.nix`, `fleetl agents sync`, check `fleet-agents` | The repository's AGENTS.md from the metadata alone (layout, hosts, services, users, caches, hardware key rules); each host's `/etc/AGENTS.md` adds sections from its modules (smartcard, access, builder, layers, comin, client). |
| ssh blocks | `modules/access.nix` (`fleet.access.sshConfig`) | A `Host` block per fleet host in `/etc/ssh/ssh_config`: agent forwarded (pam_rssh sudo needs it), multiplexed for ten minutes, `<host>-unlock` for hosts with `initrd.pub`. |
| Fleet caches | `lib/nixos/caches.nix`, `modules/client.nix` | `cache = { publicKeys; url?; port?; statusUrl?; }` in host.nix or service.nix becomes `fleet.caches`; every other host substitutes from it. |
| Nix trust | `modules/nix.nix` | Flakes on, channels off, nobody but root trusted (`trustWheel = false`; a warning when `@wheel` slips in anyway). Unsigned closures go through `sudo nix-daemon` (`pushCommand` in `lib/agents.nix`: `nix copy --no-check-sigs --to 'ssh-ng://<host>?remote-program=sudo%20nix-daemon'`). |
| `mkDeploy` | `lib/deploy.nix` | `sudoCopy` set when `sshUser` is not root; ignored by deploy-rs until its `sudoCopy` lands. |

### Testing

New checks, run like the others:

| Check | Kind | Covers |
|---|---|---|
| `unit-smartcard` | evaluation | Registration (fleet-wide and per host, `fleetReaders = false`, bad ids refused), the udev rules, scdaemon, touch detector, the hand-over to a stubbed `piv-agent`, the warning without it. |
| `unit-agents` | evaluation | The rendered AGENTS.md and a host's `/etc/AGENTS.md`; `fleet-agents` exists only once the repository has an AGENTS.md. |
| `unit-fleet` | evaluation | The ssh blocks (with and without an alias), the fleet's caches, the Nix defaults and the `@wheel` warning, the repository as a git URL (`lib/repo.nix`). |
| `agents` | build | The fixture's and the template's committed AGENTS.md are current; a stale one fails. |
| `smartcard` | VM, 2 nodes | QEMU's emulated CCID reader (`usb-ccid`): the host that registered it sees it through pcscd, the other gets `PCSCLITE_IGNORE=1` and no reader. Also scdaemon and the touch detector. |
| `push` | VM, 2 nodes | Nobody trusted: an admin's unsigned closure is refused; `sudo nix-daemon` without the forwarded agent is refused; with it the closure lands (no TTY needed); deploy-rs' `sudoCopy` URL (`ssh://…?remote-program=sudo -u root nix-store`) works; later copies find nothing to add. |

The fixture's beta host now registers a headless reader and the web service
announces a cache, so `unit-nixos` and `flake-full` cover them too.

nix-piv and deploy-rs have their own tests; see nix-piv's `HUMAN.md`, and
`nix build -L .#checks.x86_64-linux.sudo-copy` in deploy-rs.

On real hardware, once a host registers a reader:
- `udevadm info -q property -p /sys/bus/usb/devices/<port> | grep PCSCLITE_IGNORE`
  shows `0` for the registered key and `1` for anything else;
- `opensc-tool -l` lists only registered readers;
- `gpg --card-status` still works (through pcscd), and `gpgconf --kill
  scdaemon` frees the reader for PIV tools.

### Where the risk is

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

### Remaining steps

1. **nixrc:** run `nix run .#fleetl -- agents sync` and commit `AGENTS.md`;
   register the readers (fawkes, lovelace and hull attended, pavlov
   headless with `fleetReaders = false`); move the forge's cache key into
   `cache.publicKeys` of its service.nix; drop what ftl now does
   (`nixos/modules/nix.nix`, scdaemon `disable-ccid`, the touch detector
   in `profiles/hardware/smartcard.nix`).
2. **nix-piv in nixrc:** lock the published nix-piv, add
   `nix-piv.nixosModules.agent` to `nixos.sharedModules`.
3. **deploy-rs:** commit `sudo-copy`, propose it upstream (it overlaps
   with the open PR #334, which also sets `remote-program`). Until it
   lands, push with `nix copy` through `sudo nix-daemon` first.

### Milestones

The review of 2026-10-25 (a survey of nixrc and infra, an audit of
ftl) is being worked through in milestones, each one reviewed before the
next. Each is one commit, named after its milestone.

| Milestone | Content |
|---|---|
| M1: fixes before the push | `repo` as a flake reference no longer breaks `ftl-layers` (`lib/repo.nix`); the template no longer sets a follows on ftl, which has no inputs; `fleet-agents`/`fleet-sops` exist only once their file does; a warning when `@wheel` undoes `trustWheel = false`; the smartcard vocabulary shared (`lib/smartcard.nix`), caches in their own part (`lib/nixos/caches.nix`), `fleet.smartcard` no longer imports the builder; one push command (`pushCommand`); `unit-fleet` split off `unit-agents`, the `smartcard` VM test trimmed to the hardware. |
