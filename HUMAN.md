# Handover

This is for whoever takes over ftl: the state of the work, what each commit
did, and what is left. How to test it is in docs/testing.md, how to review it
in docs/review.md. Fleets built on ftl keep their own notes (deploy steps,
their migrations) in their own repositories.

State as of 2026-10-29. `git log --oneline @{u}..` shows what is not pushed;
check it before relying on anything below.

On 2026-10-29 ftl's history was rewritten from the root into the ten commits
below and force-pushed. Every checkout made before then is reset to the new
`origin/main` (`git fetch && git reset --hard origin/main`, with nothing
unpushed in it). Fleets lock ftl by revision, so **ftl is always pushed before
a fleet that locks a new revision of it**; otherwise nothing that reads that
lock can fetch ftl (comin, a fresh clone, CI).

Commits were made unsigned, meant to be signed when pushed. The pushed commits
carry no signature (`git log --format='%h %G?'` shows `N`). If signing on push
meant `git push --signed`, that leaves nothing on the commits; if it meant
signed commits, that is still to decide.

Commit subjects are `scope: sentence`, with a body of two to four lines.

## What the commits do

Oldest first (`git log --oneline`):

| Subject | In short |
|---|---|
| ftl: flake template library | Layout-driven outputs, layers, the update pipeline, the binary cache. |
| fleet: hosts, services, state and users from the layout | The `fleet` namespace, `service.nix`, `fleet.state`, `users/` and the access module. |
| secrets: a store per host, service and user, managed with fleetl | sops stores from the layout; `fleetl`. |
| lib: mkDeploy, homes per host, host key generators, test flakes | mkDeploy, homes per host, `nixos/generators/`, `tests/stable` and `tests/unstable`. |
| fleet: review fixes, code map, aliases gone, mkNixos split | `docs/architecture.md`, `lib/nixos/`, `secrets sync` by recipients, `host exec`. |
| generators: fleet-wide ones, and inputs from other generators | `scope = "fleet"` and `inputs = [ "<gen>/<file>" ]`. |
| state: backup, restore and service moves through fleet-state | `modules/backup.nix`, `scripts/fleet-state.sh`, `fleetl state …`, `fleetl service move`; the riskiest part (see `docs/review.md`). |
| fleetl: secrets move, state init, a fleet CA; HUMAN.md | `fleetl secrets move`, `fleetl state init`, `fleet-ca` and `host-tls`; this file. |
| smartcard: registered readers only; AGENTS.md from the metadata | See "Smartcards, AGENTS.md, ssh and Nix trust"; M1 below. |
| fleet: less to write downstream, consistent names, swap tests | M2 to M4 below, with their reviews. |

Commits after these are small and say what they fix.

The user-facing description is in `README.md`, under **State**, **Backups**
and **Moving a service**, and in the `fleetl` command list. The map of the
code is in `docs/architecture.md`, under `modules/` and `scripts/`.

## Testing and reviewing

docs/testing.md: how to run the suites (`checks.<sys>.fast` per commit, the
VM tests as `nix flake check`), what each check covers, a fleet's own checks
against a local ftl, and the drills on real hosts. docs/review.md: where the
risk is, the order to read the code in, the invariants, and the known gaps.

CI (GitHub Actions) runs the fast checks for every push and pull request
and the VM tests as separate jobs; a weekly job bumps each test channel's
inputs and proposes them as a pull request, checked in full
(docs/testing.md, "CI").

## Smartcards, AGENTS.md, ssh and Nix trust

Two sibling repositories go with this work:

| Repository | Branch | State |
|---|---|---|
| [nix-piv](https://github.com/FlorianFranzen/nix-piv) | `main` | `services.piv-agent.accessGroup` added, see its `HUMAN.md`; published. |
| deploy-rs (clone of serokell's) | `sudo-copy` | `sudoCopy` implemented and tested; not committed, not proposed upstream yet. |

| Piece | Where | In short |
|---|---|---|
| Reader registration | `lib/nixos/smartcards.nix` (the vocabulary in `lib/smartcard.nix`), `smartcard` in host.nix, mkFlake's `smartcard` | Readers by USB vendor, product, serial or port, for every host or one; `presence` is `attended` or `headless`. Validated eagerly; `fleet.hosts.<h>.smartcard`. |
| `fleet.smartcard` | `modules/smartcard.nix` | On only when a reader is registered. pcscd is bound to exactly those readers: a udev rule sets `PCSCLITE_IGNORE=1` on every USB device and `0` on the registered ones (pcscd has no allow-list). scdaemon through pcscd (`disable-ccid`). Attended: yubikey-touch-detector. Headless: nix-piv's `piv-agent`, its group socket, the builder joined to it. |
| AGENTS.md | `lib/agents.nix`, `modules/agents.nix`, `fleetl agents sync`, check `fleet-agents` | The repository's AGENTS.md from the metadata alone (layout, hosts, services, users, caches, hardware key rules); each host's `/etc/AGENTS.md` adds sections from its modules (smartcard, access, builder, layers, comin, client). |
| ssh blocks | `modules/access.nix` (`fleet.access.sshConfig`) | A `Host` block per fleet host in `/etc/ssh/ssh_config`, the agent forwarded for the host's own accounts only (pam_rssh sudo needs it), multiplexed for ten minutes, `<host>-unlock` for hosts with `initrd.pub`. |
| Fleet caches | `lib/nixos/caches.nix`, `modules/client.nix` | `cache = { publicKeys; url?; port?; statusUrl?; }` in host.nix or service.nix becomes `fleet.caches`; every other host substitutes from it. gc only on request. |
| Nix trust | `modules/nix.nix` | Flakes on, channels off, nobody but root trusted (`trustWheel = false`; a warning when `@wheel` slips in anyway). Unsigned closures go through `sudo nix-daemon` (`pushCommand` in `lib/agents.nix`: `nix copy --no-check-sigs --to 'ssh-ng://<host>?remote-program=sudo%20nix-daemon'`). |
| `mkDeploy` | `lib/deploy.nix` | `sudoCopy` set when `sshUser` is not root; ignored by deploy-rs until its `sudoCopy` lands. |

### Milestones

A review of 2026-10-25 (a survey of two fleets built on ftl, an audit of ftl)
was worked through in milestones, each one reviewed before the next. M1 is part
of the smartcard commit; M2 to M4 and their reviews are the commit after it.

| Milestone | Content |
|---|---|
| M1: fixes before the push | `repo` as a flake reference no longer breaks `ftl-layers` (`lib/repo.nix`); the template no longer sets a follows on ftl, which has no inputs; `fleet-agents`/`fleet-sops` exist only once their file does; a warning when `@wheel` undoes `trustWheel = false`; the smartcard vocabulary shared (`lib/smartcard.nix`), caches in their own part (`lib/nixos/caches.nix`), `fleet.smartcard` no longer imports the builder; one push command (`pushCommand`); `unit-fleet` split off `unit-agents`, the `smartcard` VM test trimmed to the hardware. |
| M2: less to write downstream | mkFlake imports the modules of known inputs (home-manager's with homes; sops-nix's and disko's when they are paths, which the module system imports once even when the fleet lists them too; comin's and lanzaboote's are functions and stay the fleet's), passes `inputs` to modules, renames registry entries (`exportInputs = { <name> = "<input>"; }`), builds the `deploy` output and deploy-rs' checks from `deploy = { sshUser; … }`, and adds a dev shell with fleetl. Hosts get `networking.hostId` from their name, their uplink from a `network` block (`fleet.network`), initrd unlock on request (`fleet.access.initrd`), `shell`/`description` from `user.nix`, `fleet.access.localPasswords` for workstations; comin's remote defaults to the fleet's repository (`fleet.comin.branch`), the builder's cache key to its own `cache` entry; a `wireguard` generator. Not done: a registry of fixed uids (a generic option is no shorter than a fleet's own helper, and setting `uid` on an undefined user creates a broken one). |
| M2 review | `networking.hostId` at priority 999 (nixpkgs' installation profiles set one with mkDefault); `networking.domain` from the fqdn at 1200, below any fleet mkDefault; initrd unlock independent of the accounts, asserting an admin key, with DHCP in the initrd when there is no `network` block; the initrd uplink owned by fleet.network wherever the initrd brings up networking; the `network` block checked; deploy-rs' checks per system with that system's hosts only; the builder trusts every key its own cache announces; a known input whose module stops being a path is warned about; the dev shell only where the fleet has none; `shell`/`description` reserved in user.nix; layers and client read the repository from fleet.meta (standalone too). |
| M3: cleanup | One key-file reader (`lib/keys.nix`), one way to reach a host (`lib/address.nix`; mkDeploy now pins keys under the host's name as the ssh blocks and fleetl do), `peers` is `hostInfo` inside mkNixos; option names that match their siblings (`fleet.layers.ntfy.url`, `fleet.builder.signing.gpgHome`, `fleet.builder.metrics.textfileDir`, `fleet.cache.dir`, `fleet.access.initrd.port`); the default fleet name is `fleet`; `notify` and `verify_commit` shared by ftl-layers and ftl-pipeline (`scripts/lib/common.sh`), the verify options and service sandboxing by builder and layers (`lib/units.nix`); `nixosModules` built from `modules/all.nix`; `ftl.lib.agents`; dead code gone (`fleet.backup.profiles`, fleet-state's `FLEET_STATE_CONF`/`FLEET_STATE_PROFILES`); testing and review moved from this file to `docs/testing.md` and `docs/review.md`; tests share the fixture's mkFlake arguments, and `checks.<sys>.fast` is everything but the VM tests. |
| M4: risks | `tests/swap.nix`: a failed second rename during a swap is put back by `swap_recover`, and a TERM or HUP in the middle of a swap is held until the entry is whole. `fleetl check` evaluates each metadata file on its own and then the fleet, naming the file that breaks every output. |
| M3/M4 review | `ftl-layers --help` prints its own header again; the `fast` set takes every check that is not a VM test; the access module's sshd policy sits above nixpkgs' mkDefaults (its installation profiles allow root); fleetl's hint about `fleetl check` only when the fleet itself fails; `NIX_CONFIG` in `lib/units.nix`. |
| Final review | The agent forwarded for a host's own accounts only (never root's, nix-daemon's or a service user's), `Match all` after the ssh blocks; gc opt-in; a reader added by a module joins the registered ones; credentials kept out of AGENTS.md; `backup --all` prunes this host's snapshots only; a swap starts a mount that was not running; the fixed-uid check sees units named `x.service`. |

## Moving a fleet to this ftl

What a fleet that wrote these by hand removes, in the commit that locks this
ftl (both merge with ftl's and nothing fails, so leftovers go unnoticed):

- its own uplink module, if it writes systemd-networkd's `10-wan` from a
  `network` block: the addresses, routes, nameservers and hosts entries would
  double. `network` in host.nix is now ftl's;
- its initrd sshd, network and root shell: `fleet.access.initrd.enable = true`
  instead (clevis or other unlocking of its own stays);
- hostId lines (ftl derives the same `md5(name)[0:8]`; a ZFS host whose
  hostId differs sets it plainly), and a domain taken from the fqdn together
  with any `mkDefault` domain fallback, which would beat ftl's;
- registry lines (`nixos.exportInputs = { <name> = "<input>"; }`),
  `specialArgs.inputs`, sops-nix's and disko's modules in `sharedModules`, a
  hand-built `deploy` and deploy-rs' `deployChecks` (mkFlake's
  `deploy = { sshUser; … }`), and generators identical to ftl's;
- `experimental-features` and `trusted-users`: `fleet.nix.trustWheel = true`
  while its deploy-rs cannot copy through sudo;
- shells and descriptions of fleet users (`shell`, `description` in
  `user.nix`), `users.mutableUsers` (`fleet.access.localPasswords`), comin
  remotes (`fleet.comin.branch`);
- a cache it wants every host to use goes into the `cache` of its host.nix or
  service.nix.

Then `fleetl agents sync` and commit `AGENTS.md`, or the `fleet-agents` check
fails. Registering a smartcard reader makes every other CCID device invisible
on that host, so register every key in use, or none.

Comparing each host's `system.build.toplevel` before and after
(docs/testing.md) shows what really changed: from this ftl, the ssh blocks,
`/etc/AGENTS.md`, channels off and fleet-state.

## Remaining steps

1. **deploy-rs:** commit `sudo-copy`, propose it upstream (it overlaps
   with the open PR #334, which also sets `remote-program`). Until it
   lands, fleets push with `nix copy` through `sudo nix-daemon` first, or
   trust wheel.
2. **CI's first runs:** allow GitHub Actions to create pull requests (the
   repository's Actions settings), watch the first `checks` run, and merge
   the first `update tests` pull requests. `tests/unstable` is locked to a
   nixpkgs that still has `boot.initrd.systemd.enable`, which newer nixpkgs
   removed (ftl copes with both, checked by hand); the first bump tests the
   newer side.
