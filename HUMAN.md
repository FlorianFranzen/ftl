# Handover

This is for whoever takes over ftl and the fleets built on it: the state of
the work, what each commit did, and what is left to do before and after the
next deploy. How to test it is in docs/testing.md, how to review it in
docs/review.md.

State as of 2026-10-29. `git log --oneline @{u}..` in each repository shows
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
pushed on 2026-10-22 (infra up to `8e5eedf`, its re-keying `5607cec`
after). On 2026-10-29 ftl's history was rewritten from the root into the
ten commits below, the smartcard and AGENTS.md work included; the tree is
unchanged. Not pushed as of this writing:
- ftl: the rewritten history (a force-push);
- infra: TLS between the hosts (`674e33a`) and two lock bumps to the old
  ftl tip, unpushed on the other workstation;
- nixrc: lock bumps to the old ftl tip, unpushed on the other workstation.

Both consumers lock ftl by revision (`jq -r .nodes.ftl.locked.rev
flake.lock`), so **ftl must always be pushed before them**. Otherwise
nothing that reads those locks can fetch ftl (comin, a fresh clone, CI).

Commits were made unsigned, meant to be signed when pushed. The commits
pushed so far carry no signature (`git log --format='%h %G?'` shows `N`).
If signing on push meant `git push --signed`, that leaves nothing on the
commits; if it meant signed commits, that is still to decide, for what is
pushed and for what is not.

ftl and infra use a `scope: sentence` subject; ftl's bodies are two to
four lines, infra's prose. nixrc uses short imperative subjects without a
body.

## What the ftl work does

The commits, oldest first (`git log --oneline` in ftl):

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
| smartcard: registered readers only; AGENTS.md from the metadata | See the last section; M1 below. |
| fleet: less to write downstream, consistent names, swap tests | M2 to M4 below, with their reviews. |

The user-facing description is in `README.md`, under **State**, **Backups**
and **Moving a service**, and in the `fleetl` command list. The map of the
code is in `docs/architecture.md`, under `modules/` and `scripts/`.

In infra, `99c1d01` moves the Storage Box backups onto ftl's `fleet.backup`;
the later infra and nixrc commits named `flake: …ftl…` only bump the lock
(infra's last one also runs the setup service in its backup test).

## Testing and reviewing

docs/testing.md: how to run the suites (`checks.<sys>.fast` per commit, the
VM tests as `nix flake check`), what each check covers, infra's checks and
the drills on real hosts. docs/review.md: where the risk is, the order to
read the code in, the invariants, and the known gaps.

## Remaining steps

In order:

1. **Push, with no deploy in between:** infra's unpushed commits from the
   other workstation, then ftl (`git push --force-with-lease`), then the
   migrations of nixrc and infra (M5 below), which relock them to the new
   ftl. Reset every other ftl checkout to the new `origin/main`. Decide on
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
8. **Run the drills** (docs/testing.md, "Drills on the real hosts"): a backup, a restore with rollback on a cheap
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

## Smartcards, AGENTS.md, ssh and Nix trust (2026-10-24)

The commits `smartcard: registered readers only; AGENTS.md from the
metadata` and `fleet: less to write downstream, consistent names, swap
tests` (see "Milestones" below). It also touches access, client and mkDeploy. Two sibling
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

### Remaining steps

1. **nixrc:** AGENTS.md, the forge's cache and `nixos/modules/nix.nix`
   are done on the `ftl-migration` branch (M5). Left: register the readers
   (fawkes, lovelace and hull attended, pavlov headless with
   `fleetReaders = false`) once their USB ids are known, then drop the
   touch detector from `nixos/profiles/hardware/smartcard.nix` (ftl turns
   it on for attended hosts); `disable-ccid` in
   `home/profiles/desktop/gnupg.nix` repeats what ftl sets and may stay.
2. **nix-piv in nixrc:** lock the published nix-piv, add
   `nix-piv.nixosModules.agent` to `nixos.sharedModules`.
3. **deploy-rs:** commit `sudo-copy`, propose it upstream (it overlaps
   with the open PR #334, which also sets `remote-program`). Until it
   lands, push with `nix copy` through `sudo nix-daemon` first.

### Milestones

The review of 2026-10-25 (a survey of nixrc and infra, an audit of
ftl) was worked through in milestones, each one reviewed before the
next; M5 is what is left. M1 is part of the smartcard commit; M2 to M4 and their reviews are
the commit after it.

| Milestone | Content |
|---|---|
| M1: fixes before the push | `repo` as a flake reference no longer breaks `ftl-layers` (`lib/repo.nix`); the template no longer sets a follows on ftl, which has no inputs; `fleet-agents`/`fleet-sops` exist only once their file does; a warning when `@wheel` undoes `trustWheel = false`; the smartcard vocabulary shared (`lib/smartcard.nix`), caches in their own part (`lib/nixos/caches.nix`), `fleet.smartcard` no longer imports the builder; one push command (`pushCommand`); `unit-fleet` split off `unit-agents`, the `smartcard` VM test trimmed to the hardware. |
| M2: less to write downstream | mkFlake imports the modules of known inputs that are paths (home-manager, sops-nix, disko; a path is imported once even when the fleet lists it too; comin's and lanzaboote's are functions and stay the fleet's), passes `inputs` to modules, renames registry entries (`exportInputs = { nixrc = "self"; }`), builds the `deploy` output and deploy-rs' checks from `deploy = { sshUser; … }`, and adds a dev shell with fleetl. Hosts get `networking.hostId` from their name, their uplink from a `network` block (`fleet.network`, infra's module generalized), initrd unlock (`fleet.access.initrd`), `shell`/`description` from `user.nix`, `fleet.access.localPasswords` for workstations; comin's remote defaults to the fleet's repository (`fleet.comin.branch`), the builder's cache key to its own `cache` entry; a `wireguard` generator. Not done: a registry of fixed uids (a generic option is no shorter than infra's helper, and setting `uid` on an undefined user creates a broken one). **Migration:** the reviews found what each consumer must change in the commit that bumps ftl; see "Migrating nixrc and infra" below. |
| M2 review | `networking.hostId` at priority 999 (nixpkgs' installation profiles set one with mkDefault); `networking.domain` from the fqdn at 1200, below any fleet mkDefault; initrd unlock independent of the accounts, asserting an admin key, with DHCP in the initrd when there is no `network` block; `fleet.access.initrdPort` is `initrd.port` (rename error, migration script); the initrd uplink owned by fleet.network wherever the initrd brings up networking; the `network` block checked; deploy-rs' checks per system with that system's hosts only; the builder trusts every key its own cache announces; a known input whose module stops being a path is warned about; home-manager's module always imported with homes; the dev shell only where the fleet has none; `shell`/`description` reserved in user.nix; layers and client read the repository from fleet.meta (standalone too). |
| M3: cleanup | One key-file reader (`lib/keys.nix`), one way to reach a host (`lib/address.nix`; mkDeploy now pins keys under the host's name as the ssh blocks and fleetl do), `peers` is `hostInfo` inside mkNixos; option names that matched their siblings (`fleet.layers.ntfy.url`, `fleet.builder.signing.gpgHome`, `fleet.builder.metrics.textfileDir`, `fleet.cache.dir`, `fleet.access.initrd.port`; neither nixrc nor infra set the old ones); the default fleet name is `fleet`; `notify` and `verify_commit` shared by ftl-layers and ftl-pipeline (`scripts/lib/common.sh`), the verify options and service sandboxing by builder and layers (`lib/units.nix`); `nixosModules` built from `modules/all.nix`; `ftl.lib.agents`; dead code gone (`fleet.backup.profiles`, fleet-state's `FLEET_STATE_CONF`/`FLEET_STATE_PROFILES`); docs drift fixed, testing and review moved from this file to `docs/testing.md` and `docs/review.md`; tests share the fixture's mkFlake arguments, and `checks.<sys>.fast` is everything but the VM tests. |
| M4: risks | `tests/swap.nix`: a failed second rename during a swap is put back by `swap_recover`, and a TERM or HUP in the middle of a swap is held until the entry is whole (both checked against the intent of fleet-state; no script change). `fleetl check` evaluates each metadata file on its own and then the fleet, naming the file that breaks every output; every command that cannot evaluate the fleet points to it. |
| M3/M4 review | `ftl-layers --help` prints its own header again (common.sh comes first in the packaged script); the `fast` set takes every check that is not a VM test (none can be forgotten); the access module's sshd policy sits above nixpkgs' mkDefaults (its installation profiles allow root, which made nixrc's installers fail once nixrc dropped its own mkForce); fleetl's hint about `fleetl check` only when the fleet itself fails; `NIX_CONFIG` in `lib/units.nix`; the test of `fleetl check` is `fleetl-check`; dangling "above" references after the split, and the docs' test rows, fixed. |
| M5: nixrc and infra | nixrc: branch `ftl-migration` in the worktree `~/Nix/nixrc-ftl-migration` (off nixrc `master` 04216a6; four commits: defaults ftl provides dropped with `fleet.nix.trustWheel = true` and `fleet.access.localPasswords = true`, shell and description in `users/florian/user.nix`, the forge's cache announced in its `service.nix` and its pipeline on `master`, a generated AGENTS.md). Every host evaluates against this ftl; the closures differ from `master`'s only by the fleet cache (substituter, `ftl-status`) and AGENTS.md. Its `flake.lock` still names an old ftl: relocking it to the new ftl is the migration itself, so after the force-push `nix flake update ftl` on the branch, check, merge and push at once. No smartcard readers are registered: once one is, every other CCID device is ignored, so the YubiKey, Nitrokey, Ledger and Solo 2 need their ids first. infra: waits for infra to be pushed from the other workstation (674e33a and two lock bumps), then is done here on top of it as the commit that relocks ftl: `fleet.network` replacing infra's network.nix, a committed AGENTS.md (`fleetl agents sync`, or the `fleet-agents` check fails), the `trustWheel` default and the rest of "Migrating nixrc and infra", with infra's own checks. |

### Migrating nixrc and infra

What each consumer changes in the commit that moves it to this ftl (from the
reviews of M2; the M5 milestone does it):

- infra:
  - delete `nixos/modules/network.nix` in the same commit, or the `10-wan`
    lists (addresses, routes, nameservers, hosts entries) double: both merge,
    nothing fails;
  - `nixos/modules/unlock.nix`: drop the initrd sshd, network and shell (they
    read `infra.network.initrd`, which is gone), keep clevis and `device`;
    hosts set `fleet.access.initrd.enable = true` instead of
    `infra.unlock.enable`;
  - delete `defaults.nix`'s hostId and registry lines, the `wireguard`
    generator (identical to ftl's), and in `flake.nix` `specialArgs.inputs`,
    `sharedModules` (sops-nix, disko), the hand-built `deploy` and
    `deployChecks`; `exportInputs = { nixrc = "self"; nixpkgs = "nixpkgs"; }`;
  - `common.nix`: replace experimental-features and trusted-users with
    `fleet.nix.trustWheel = true` (its deploy-rs has no sudoCopy yet);
  - keep its own dev shell (it has more than ftl's).
- nixrc:
  - delete `nixos/modules/nix.nix` (`fleet.nix.trustWheel = true` instead),
    hostPlatform in `defaults.nix` and the two aarch64 hosts, the sshd/rssh
    lines of `defaults.nix`, its hostId lines, `florian.nix` (with
    `shell = "zsh"; description = …;` in `users/florian/user.nix`);
  - `defaults.nix`: `fleet.access.localPasswords = true` instead of
    `mutableUsers`;
  - `deploy.nix`: drop the repo URL, comin remotes and `fleet.layers.repo`,
    set `fleet.comin.branch = "master"`; `forge.nix`'s `branch = "ftl"` is
    stale, it should be `master`;
  - announce the forge's cache in its `service.nix` (`cache.publicKeys`,
    `port = 8080`); every other host then substitutes from it and gets
    `ftl-status` (gc only with `fleet.client.gc.automatic`);
  - smartcards: once readers are registered, every other CCID device is
    ignored, so register the YubiKey, Nitrokey, Ledger and Solo 2, or none.
