# Testing ftl

How to run ftl's tests, what each covers, the checks of the fleets built on it,
and the drills on real hosts. (Moved from HUMAN.md; that file keeps the
state of the work and what is left.)

## Prerequisites

- **Nix:** flakes enabled. The suites were run with Nix 2.34.
- **VM tests:** KVM, a few GB of RAM per test, and disk for the VM images.
  The `move` test runs four VMs at once.
- **Time:** a full suite took tens of minutes on a 32-core machine. Single
  checks take one to five minutes.

## The ftl suites

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

Every check but the VM tests (a minute or two, for each commit):

```
nix build --no-link --no-write-lock-file -L ./tests/unstable#checks.x86_64-linux.fast
```

One check:

```
nix build --no-link --no-write-lock-file -L ./tests/unstable#checks.x86_64-linux.<name>
```

| Check | Kind | Covers |
|---|---|---|
| `unit-loader`, `unit-static`, `unit-packages`, `unit-home`, `unit-nixos`, `unit-users`, `unit-deploy` | evaluation | Each `mk*` function on `tests/fixtures/layout`. `unit-nixos` includes stores, generators (scopes, inputs, cycles) and services. |
| `flake-isolated`, `flake-full`, `flake-wiring` | evaluation | `mkFlake` with one family at a time, with all of them, and what it wires up for a consumer (input modules, `inputs`, registry names, `deploy`, the dev shell). |
| `cli` | build | `fleetl` on stubs: `.sops.yaml` rendering, `secrets move`, `host exec`, `state …` commands, fleet and host generators end to end. |
| `generators` | build | Each generator, ftl's own (`host-keys`, `age-key`, `fleet-ca`, `host-tls`, `wireguard`) and the fixture's, writes exactly the files it declares; the certificates verify against their CA. |
| `modules` | VM | A host with the builder, the cache and the client enabled, and what the fixture's metadata turns on. |
| `state-btrfs`, `state-zfs` | VM | `fleet.state` on an empty disk: boot without the filesystem, then creation and mounts. |
| `backup-btrfs`, `backup-zfs` | VM | See below. |
| `move` | VM, 4 nodes | See below. |
| `swap` | VM | fleet-state's swap under failure: `swap_recover` after a failed second rename, TERM and HUP held until the entry is whole. |
| `fleetl-check` | build | `fleetl check` names the broken metadata file. |
| `layers`, `pipeline`, `pipeline-agent`, `cache` | VM | Layers and the update pipeline (the oldest part of ftl). |
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
  tags (by an older fleet-state);
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

## CI

GitHub Actions run the same suites (`.github/workflows/`, the runner setup
in `.github/actions/nix`: KVM opened, disk freed):

- `checks`: `fast` on both channels for every push to `main` and every pull
  request, then each VM test as a job of its own on unstable; on Mondays and
  when started by hand, the VM tests on both channels.
- `update tests`: on Mondays and when started by hand, each channel's lock
  bumped to its inputs' heads (`nix flake update --flake ./tests/<channel>`),
  every check run against it in that job, and a pull request opened or
  refreshed on `update/tests-<channel>` with what changed and what failed.
  Merging it moves the suite to the new inputs; a failing one says what a
  newer nixpkgs, home-manager, sops-nix, comin or deploy-rs breaks.

Pull requests from that workflow need "Allow GitHub Actions to create and
approve pull requests" in the repository's Actions settings. Opened with
the workflow's own token they start no other workflow, which is why the job
checks for itself; a `FLAKE_UPDATE_TOKEN` secret (a fine-grained token with
contents and pull-requests write) makes the regular checks run on them too.

## A fleet's own checks against a local ftl

To try a fleet against a local, unpushed ftl, add
`--override-input ftl path:/path/to/ftl` (or
`git+file:///path/to/ftl?rev=<rev>` for an exact commit) to its
`nix build .#checks…` or `nix flake check`. The same works for
`nix run .#fleetl -- …`.

To compare a host before and after a change without touching the working
tree, evaluate both versions of ftl and diff them:

```
a=$(nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath)
b=$(nix eval --raw --override-input ftl path:/path/to/ftl .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath)
nix run nixpkgs#nix-diff -- "$a" "$b"
```

Compare against the committed lock rather than a `git stash`ed "before"
state, which a parallel change in the same checkout would get mixed into.

## Drills on the real hosts, after the deploy

The VM tests do not touch the real Storage Box or real services, and they
reboot only once (a source between its freeze and its deploy). Before trusting restores and moves with
anything that matters, run these once.

1. **A backup.** On any host:
   - `sudo systemctl start fleet-backup`, then `sudo fleet-state snapshots`.
   - The new snapshots carry `fleet-entry:`, `fleet-service:` and
     `fleet-root:` tags.
   - `/var/lib/prometheus-node-exporter-text-files/fleet-backup.prom` exists.
   - The alerts `BackupOverdue` and `BackupMissing` stay quiet.
2. **A restore of something cheap**, an entry whose loss would not hurt:
   - `fleetl state restore <host> <entry>`; the service comes back on its own.
   - `fleetl state list <host>` shows the copy kept aside.
   - `fleetl state rollback <host> <entry>` swaps it back.
   - `fleetl state discard <host> <aside>` removes it.
3. **A move of a throwaway service.** Do not start with a real service.
   - Add a small service (one state entry, one unit, a fixed uid) to two
     hosts' reach, and give it some data.
   - `fleetl service move <svc> <host>`, commit, deploy the target, then
     the source.
   - Check the data on the target, then `fleetl state drop <source> <entry> <kind>`
     (data left behind with `--without-data` needs `--force`).
   - Repeat with `--via backup`.

## Smartcards, AGENTS.md, access and Nix trust

Their checks, run like the others:

| Check | Kind | Covers |
|---|---|---|
| `unit-smartcard` | evaluation | Registration (fleet-wide and per host, `fleetReaders = false`, bad ids refused), the udev rules, scdaemon, touch detector, the hand-over to a stubbed `piv-agent`, the warning without it. |
| `unit-agents` | evaluation | The rendered AGENTS.md and a host's `/etc/AGENTS.md`; `fleet-agents` exists only once the repository has an AGENTS.md. |
| `unit-fleet` | evaluation | The ssh blocks (with and without an alias), the fleet's caches and the builder's own key, the Nix defaults and the `@wheel` warning, the repository as a git URL (`lib/repo.nix`), the `network` uplink (IPv6 gateway, delegated prefix, IPv4 only, by MAC or name), initrd unlock (and its DHCP, its admin-key assertion), accounts from `user.nix`, local passwords, hostId and domain, comin's remote. |
| `agents` | build | The fixture's and the template's committed AGENTS.md are current; a stale one fails. |
| `smartcard` | VM, 2 nodes | QEMU's emulated CCID reader (`usb-ccid`): the host that registered it sees it through pcscd, the other gets `PCSCLITE_IGNORE=1` and no reader. Also scdaemon and the touch detector. |
| `push` | VM, 2 nodes | Nobody trusted: an admin's unsigned closure is refused; `sudo nix-daemon` without the forwarded agent is refused; with it the closure lands (no TTY needed); deploy-rs' `sudoCopy` URL (`ssh://…?remote-program=sudo -u root nix-store`) works; later copies find nothing to add. |

The fixture's beta host registers a headless reader and the web service
announces a cache, so `unit-nixos` and `flake-full` cover them too.

nix-piv and deploy-rs have their own tests; see nix-piv's `HUMAN.md`, and
`nix build -L .#checks.x86_64-linux.sudo-copy` in deploy-rs.

On real hardware, once a host registers a reader:
- `udevadm info -q property -p /sys/bus/usb/devices/<port> | grep PCSCLITE_IGNORE`
  shows `0` for the registered key and `1` for anything else;
- `opensc-tool -l` lists only registered readers;
- `gpg --card-status` still works (through pcscd), and `gpgconf --kill
  scdaemon` frees the reader for PIV tools.
