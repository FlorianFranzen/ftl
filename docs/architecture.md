# ftl, module by module

What every part of ftl reads, what it provides, and how it works. The README
is the user's view (conventions, examples); this is the map of the code.

```
repository                    lib/ (pure functions)                      flake outputs
──────────                    ─────────────────────                      ─────────────
pkgs/      ──► mkPackages ──────────────────────────────────────────────► overlays, packages, legacyPackages
static/    ──► mkStatic ─────┐                                            (module argument `static`)
home/      ──► mkHome ───────┼─► homes, companions ─┐                    homeModules, homeProfiles, homeConfigurations
users/     ──► mkUsers ──────┼─► user specs ────────┤
nixos/     ──► mkNixos ◄─────┘                      │                    nixosConfigurations, nixosModules, nixosProfiles,
                 hosts, services, layers, ◄─────────┘                    nixosLayers, nixosServices, fleet.*, packages.*
                 generators, users, stores                                 (fleetl, generate-*), apps, checks
               ──► mkLayer, mkManifest, mkDeploy
                                       │
                 mkFlake orchestrates all of the above and injects modules/flake.nix
                                       │
modules/   (NixOS modules on every host, all off by default except what mkNixos sets)
scripts/   (shell, packaged by modules/scripts.nix: fleetl, ftl-layers, ftl-pipeline, ...)
```

Two rules hold throughout. **Metadata is never a module**: `host.nix`,
`service.nix` and `user.nix` are plain attribute sets read before any NixOS
evaluation, so everything derived from them (`fleet.hosts`, stores, deploy
nodes) is safe to use in `imports`. **`ftl` on disk, `fleet` in Nix**: file
names, scripts and `/var/lib/ftl` keep the short name; options, outputs and
module arguments use `fleet`.

## lib/

### `lib/loader.nix`

- Reads: a directory.
- Provides: `loadTree { dir; exclude }` (nested attrset of `.nix` paths,
  `foo.nix` → `foo`, directories recurse, `default.nix` is an ordinary entry),
  `loadTreeIfExists`, `collectPaths` (depth-first list of the paths).
- Used by every `mk*` that walks a folder.

### `lib/kinds.nix`

- Provides: the layer kinds (`packages`, `units`) and `check`, which rejects
  any other.
- Used by `mkLayer`, `mkNixos` and `modules/layers.nix`, so a kind is
  normalised the same way wherever it is read.

### `lib/packages.nix` — `mkPackages`

- Reads: `pkgs/<name>/package.nix` (callPackage, by-name shape),
  `pkgs/overlay.nix`, `pkgs/config.nix`; arguments `nixpkgs`, `systems`,
  `overlays` (applied before the local one), `config`.
- Provides: `overlay`, `overlays` (all of them), `config`, `packages.<sys>`
  (the local packages that build on that system), `pkgs.<sys>` and `pkgsFor`
  (the package set every other family uses).
- How: one `import nixpkgs` per system with the overlays and config; the
  by-name packages become an overlay so they can refer to each other.

### `lib/static.nix` — `mkStatic`

- Reads: `static/`.
- Provides: the `static` module argument: files by name without their last
  extension, directories with an `outPath`, so `static.wallpapers.dark` or
  `doomDir = static.emacs` copy the same store path a path literal would.

### `lib/home.nix` — `mkHome`

- Reads: `home/modules/**.nix`, `home/profiles/<dir>/*.nix`,
  `home/variants/*.nix`; arguments `bases` (name → list of profile dirs),
  `username`, `sharedModules`, `extraSpecialArgs`, `systems`, and the
  `home-manager` flake when present.
- Provides: `homeModules`, `homeProfiles`, `modules.<base>-<variant>` (the
  configurations as home-manager modules; `homes` in NixOS hosts),
  `companions.<name>` (the `nixos.nix` of each profile dir in the base: the
  NixOS side that configuration needs), `configurations.<sys>.<name>` (built
  with `homeManagerConfiguration` when home-manager is there), `checks`,
  `manifestEntries`.
- How: a base includes only the *direct* `.nix` files of each listed dir
  (`nixos.nix` excluded); every base is combined with every variant.

### `lib/users.nix` — `mkUsers`

- Reads: `users/<name>/user.nix` (metadata), `ssh.pub`, `sops.pgp`,
  `sops.age` (one entry per line, comments allowed).
- Provides: `users.<name>` = the metadata plus `dir` and
  `keys = { ssh; pgp; age; }`. Nothing is resolved here; `mkNixos` does that.

### `lib/nixos.nix` — `mkNixos`

The hub. It reads the `nixos/` folder and the specs the other families hand
it, and produces every host-related output. The work is split by entity into
`lib/nixos/`: `hosts.nix` (discovery, validation, `fleet.hosts`),
`services.nix` (discovery, roles, the `service` argument, `nixosServices`),
`users.nix` (placement, homes and their companions, `fleet.users`),
`sops.nix` (stores and recipients), `generators.nix` and `layers.nix`. Each
part is a function of one shared context: the arguments below plus every
other part's results (`lib.fix`), so the parts are read in any order while
the data flows acyclically (services need the host specs, users the
services, hosts their services and users, the stores all three).
`nixos.nix` itself only assembles the configurations, checks and manifest.

- Reads: `nixos/hosts/<h>/` (`host.nix` metadata; `*.nix` modules; `*.pub`
  and `sops.age` key files; `secrets.yaml`, `identity.yaml`),
  `nixos/modules/**.nix`, `nixos/profiles/**.nix`, `nixos/layers/<l>.nix`,
  `nixos/services/<s>/` (`service.nix` metadata, `*.nix` modules, `home.nix`
  skipped), `nixos/generators/<g>.nix` plus ftl's own in `lib/generators/`;
  arguments `hosts`, `layers`, `services`, `users` (explicit specs merged over
  the discovered ones), `homes` and `homeCompanions` (from `mkHome`),
  `static`, `specialArgs`, `sharedModules`, `extraProfiles`, `pkgsFor`,
  `name`, `repo`, `root` (the repository root, for store paths).
- Provides:
  - `nixosConfigurations.<h>` (each with `fleetArgs`, the exact
    `nixosSystem` arguments, for VM tests), `nixosModules`, `nixosProfiles`,
    `nixosLayers.<sys>.<l>`, `nixosServices.<s>` (a service as a plain module);
  - `fleet.hosts` (every host's metadata: name, system, importance,
    layers, services, users, generators, keys, free-form data),
    `services`/`fleet.services`, `users`/`fleet.users`, `keys`/`fleet.keys`
    (the fleet's `nixos/<name>.pub` files);
  - `sops.stores` (every store with its recipients: pgp and age keys, and the
    SSH host keys still to be converted), `generators` (what each makes) and
    `generatorPrograms system` (each as a program);
  - `checks` (`nixos-<h>`, `nixos-layer-<l>`) and `manifestEntries`.
- How, in order:
  1. hosts and services are discovered and validated (unknown layers,
     services, generators, home configurations fail eagerly);
  2. a host's layers are its own plus its services'; its users are the admins
     plus whoever lists it or one of its services; its home per user comes
     from `user.nix` (`home` as a name or `{ default; <host>; }`);
  3. every host gets: `sharedModules`, ftl's modules (`modules/*.nix`, all
     disabled by default), `nixos/modules`, its services' modules (wrapped so
     they receive the `service` argument), its own modules, the companions of
     its users' homes, and a meta module that sets `fleet.meta`,
     `fleet.layers.installed`, `fleet.secrets.file`/`ageKeyFile`,
     `networking.hostName` and `nixpkgs.hostPlatform`;
  4. the special arguments are `profiles`, `homes`, `static`, `fleet`
     (`hosts`, `services`, `users`, `self`).
- Service modules: a module file is wrapped with `lib.setFunctionArgs` so
  that `service` (metadata, `role`, `dir`, `sopsFile`) is injected without
  the module system looking it up; `nixosServices.<s>` uses the same wrapper
  with the roles resolved lazily from `config.fleet.meta.host`.
- Stores: the fleet's `nixos/secrets.yaml` is for every host and the admins,
  its `nixos/identity.yaml` for the admins; a host's `secrets.yaml` is for
  the host and the admins, its `identity.yaml` for the admins; a service's
  `secrets.yaml` for its hosts, the admins and the users listing it; a
  user's for that user. A host is a recipient by its `sops.age` if present,
  else by its `ssh.pub`.

### `lib/layer.nix` — `mkLayer`

- Reads: `{ pkgs; name; kind; packages; units; }`.
- Provides: a `buildEnv` with the packages, generated unit files (kind
  `units`) and `share/ftl-layer/meta.json` (`{ name; kind; units; }`), which
  `ftl-layers` reads on the host.

### `lib/manifest.nix` — `mkManifest`

- Reads: entries from `mkNixos` and `mkHome`.
- Provides: `fleet.manifest` (`{ name; repo; version; attrs.<sys>.<check> =
  { kind; host; layer; importance; configAttr; flakeAttr; } }`), the only
  contract between a repository and the pipeline: `ftl-pipeline` never parses
  attribute names.

### `lib/deploy.nix` — `mkDeploy`

- Reads: `fleet.hosts`, `nixosConfigurations`, the deploy-rs flake, `address`
  (host data → address, default `fqdn` or name), `sshUser`, `user`,
  `sshOpts`, `exclude`.
- Provides: the `deploy` output (`nodes`, `sshUser`) and `knownHosts`, a file
  with every host's `ssh.pub`; nodes with a key are pinned to it
  (`HostKeyAlias`, `UserKnownHostsFile`, `StrictHostKeyChecking=yes`).

### `lib/generators/*.nix`

- `host-keys`: SSH host key and initrd key (`ssh.pub`, `initrd.pub`; private
  halves in `identity.yaml`). On every host by default.
- `age-key`: a dedicated age key (`sops.age`; key in `identity.yaml`).
- Shape of any generator: `{ pkgs }: { description; scope; inputs;
  runtimeInputs; files; script; }`, where `files.<f> = { secret; store; }`.
  `scope` is `host` (per host, listed in `host.nix`, files next to it and in
  its stores) or `fleet` (once, files in `nixos/` and in `nixos/secrets.yaml`
  or `nixos/identity.yaml`; `nixos/<name>.pub` is `fleet.keys.<name>`).
  `inputs` lists files of other generators (`<generator>/<file>`) the script
  reads under `$in`; `mkNixos` checks that they exist, are declared, do not
  loop, and that a fleet generator reads fleet files only. The program is
  `generate-<name> <out> [<in>]`.

### `lib/flake.nix` — `mkFlake`

- Reads: `src` (the repository), `inputs` (`nixpkgs` required;
  `home-manager`, `sops-nix` used when present), `name`, `repo`, `systems`,
  `layout` (folder names, `null` disables a family), `overlays`, `config`,
  `nixos.*`, `home.*`, `users`, `sops.extraRules`; anything else is
  deep-merged into the outputs.
- Provides: everything above as flake outputs, plus `fleet.sops` (stores +
  `extraRules`), `packages.<sys>.fleetl` and `generate-<g>`, `apps.<sys>.fleetl`,
  `checks.<sys>.fleet-sops`.
- How: decides statically which families exist (so touching one output never
  evaluates another's nixpkgs), builds the integration module
  (`modules/flake.nix`) and hands the home results to `mkNixos`.

## modules/

Every module is importable on its own (`ftl.nixosModules.<name>`); `mkNixos`
imports all of them into every host and sets what it knows. Options live
under `fleet.*`.

| module | reads | provides | depends on being loaded by mkNixos? |
|---|---|---|---|
| `meta` | — | `fleet.meta` (`environment`, `repo`, `host`, `attr`, `importance`, `system`, `layers`, `services`, `users`) | set by mkNixos; standalone it is empty |
| `dirs` | — | `fleet.rootDir` (`/var/lib/ftl`; `state/`, `status/`, `cache/`, `keys/` below it) | no |
| `flake` (injected, not exported) | `inputs`, overlays, nixpkgs config, home results | `nixpkgs.overlays`/`config`, flake registry and `NIX_PATH` for `exportInputs`, `system.configurationRevision`, home-manager wiring | mkFlake only |
| `builder` | `fleet.builder.*` (repos and lanes, signing, verify, cache, remote builders), `fleet.rootDir` | the `ftl-pipeline-<repo>-<lane>` services and timers, the `ftl` user, directories, nix-daemon signing | no |
| `cache` | `fleet.cache.*`, `fleet.rootDir` | nginx serving `cache/` and `status/` | no |
| `client` | `fleet.client.*` | substituters, gc defaults, `ftl-status` | no |
| `layers` | `fleet.layers.*` (`installed` set by mkNixos, `repo`, `verify`, timer) | `environment.profiles` for packages layers, a systemd generator linking units layers, `ftl-layers` and its update service and timer, `fleet.layers.hook` | `installed` comes from mkNixos; settable by hand |
| `comin` | `fleet.comin.*`, whether comin's and lanzaboote's modules are present | `services.comin.postDeploymentCommand` = the hook (system profile sync for lanzaboote, then layer update) | no |
| `state` | `fleet.state.<name>` (`path`, `kind`, `units`, `service`, `backup`, `snapshots`, `zfs.properties`), `fleet.storage` (`btrfsDevice`, `zfsPool`, `zfsProperties`, `tool.enable`), `fleet.backup.enable` | the `fleet-state` service creating subvolumes/datasets, one mount unit per entry, `RequiresMountsFor` on its units, assertions (fixed uids or `DynamicUser`, entry names); the `fleet-state` tool and `/etc/fleet-state/state.json` (backend, device or pool, host, entries with ZFS properties) where there are entries, a ZFS pool or backups; an activation snippet lifting the blocks of entries no longer declared | no |
| `backup` | `fleet.backup.*` (`repositories.<kind>`, `passwordFile`, `credentialFiles`, `packages`, `schedule`, `retention`, `metrics.textfileDir`), `fleet.state` | `/etc/rustic/<kind>.toml` (also `fleet.backup.profiles`), `/etc/fleet-state/backup.json`, the `fleet-backup` service and timer (`fleet-state backup --all`), `fleet-backup-init` | no |
| `access` | `fleet.access.*` (`users` defaults to the host's fleet users, `sudo`, `knownHosts`, `initrdPort`); the `fleet` argument when present | accounts with keys and no password, sshd without passwords or root, sudo via pam_rssh, every host's keys in `known_hosts` | `users` and `knownHosts` need `fleet`; standalone, set `fleet.access.users` |
| `secrets` | `fleet.secrets.*` (`file`, `shared` and `ageKeyFile` set by mkNixos); whether sops-nix's module is present | `sops.defaultSopsFile`, `sops.age.keyFile`, `sops.gnupg.sshKeyPaths = []`; `shared` for modules to point a secret at | `file` comes from mkNixos; settable by hand |
| `scripts` (a function, not a module) | `pkgs` | the packaged scripts: `fleetl` (+`ftl` alias), `ftl-layers`, `ftl-status`, `ftl-pipeline`, `ftl-cache-retention` | no |

## Standalone use

Each module can be imported on its own (`ftl.nixosModules.<name>`); what
`mkNixos` would set has to be set by hand then:

| module | set by hand |
|---|---|
| `layers` | `fleet.layers.installed.<l>.kind`, `fleet.layers.repo` |
| `access` | `fleet.access.users` (without the `fleet` argument there are no accounts and no known hosts) |
| `secrets` | `fleet.secrets.file`, `fleet.secrets.shared`, `fleet.secrets.ageKeyFile` |
| `meta` | nothing; `fleet.meta.host` is null, which `nixosServices` tolerates (`service.role = []`) |
| `nixosServices.<s>` | the special arguments its modules use (`fleet`, `profiles`, ...); it is meant for other configurations of the same fleet |

`mkNixos` without `src` takes `hosts`, `layers`, `services`, `users` as
arguments; stores need `root`.

## Files and formats

- `host.nix`, `service.nix`, `user.nix`: plain attribute sets; the reserved
  attributes are, for hosts, `system importance layers services users
  generators` (plus `name`, `modules`, `dir`, never set by hand); for
  services `hosts roles layers` (plus `name`, `modules`, `dir`); for users
  `admin hosts services home uid groups` (plus `name`, `keys`, `dir`).
  Everything else is free-form data and appears in `fleet.*`.
- `ftl-layers.json` (repository root): `{ "<layer>": "latest" | "<commit>" }`,
  written by the pipeline, read by `ftl-layers`.
- `fleet.manifest`: `{ name; repo; version = 1; attrs.<sys>.<check> = { kind
  = "nixos" | "layer" | "home"; host; layer; importance; configAttr;
  flakeAttr; } }`.
- `share/ftl-layer/meta.json` in a layer: `{ name; kind; units; }`.
- `<rootDir>/status/<name>.json` (builder): the lane's last run per check;
  `<rootDir>/state/promoted.jsonl`: one line per promotion
  (`{ attr; rev; date; outPath; }`), the retention's input.
- `.sops.yaml`: generated; `creation_rules` with one `path_regex` per store,
  `key_groups` of `pgp` fingerprints and `age` recipients.

## scripts/

- `fleetl.sh` (admin's machine, inside the repository): reads the flake's
  `fleet` output (`nix eval --json .#fleet.*`); `secrets sync` renders
  `.sops.yaml` from `fleet.sops` (SSH host keys through ssh-to-age) and
  re-keys the stores whose recipients, which sops keeps in the clear, differ from their rule (`sops updatekeys`, needs the admin's key); `host
  generate` runs `packages.<sys>.generate-<g>` into a temporary directory,
  places public files, re-renders `.sops.yaml`, and writes secrets into the
  stores (a new store in one `sops --encrypt`; an existing one with `sops set`,
  which needs the admin's key); `host install` unpacks `identity.yaml` for
  nixos-anywhere; `fleet generate` runs the fleet-scoped generators the same
  way, into `nixos/`; a generator's inputs are made first when missing and
  put under `$in` (a secret decrypted from its store, which needs the
  admin's key); `host exec` runs a command on a host (or on every host that
  is not ignored) at the deploy output's address and login (else the host's
  `fqdn` or name, and root), pinned to its `ssh.pub` the way `mkDeploy` pins
  deploys; `state` runs `fleet-state` on a host as root, its arguments
  quoted for the remote shell (bash's `printf %q`), through `sudo` with the
  agent forwarded (pam_rssh) unless the login is root; root on that host
  can use the agent while it is forwarded. `service move` reads the
  service from `fleet.services`, its entries from the old host's
  `nixosConfigurations.<h>.config.fleet.state` and the new host's for
  collisions, edits `service.nix` with a string replacement it checks by
  evaluating `fleet.services` again, then drives `fleet-state` on both
  hosts (`stop`, `backup`, `send | receive` or with `--via backup`
  `access | receive --from-backup --snapshot <id the backup printed>`,
  `place`, `freeze --stopped`) and `secrets sync`, under a lock in the
  repository's git directory; each step's undo (`start`, `abort`, `thaw`;
  `drop` once `place` succeeded) is recorded before the step, so a step
  that fails halfway is undone too. It refuses when the old host would
  have no `fleet-state` after its deploy. `state copy` is `send | receive`
  and `place --replace` for one entry. Temporary directories are `0700` and
  removed on any exit.
- `fleet-state.sh` (hosts, as root; packaged by `modules/state.nix` with the
  host's ZFS or btrfs tools): reads `/etc/fleet-state/state.json` (backend,
  device or pool, host, entries with their ZFS properties) and, with backups
  on, `backup.json` and `/etc/rustic/<kind>.toml`.
  - Content is always read from a read-only snapshot of the entry's dataset
    or subvolume (ZFS: `<dataset>@<tag>`, mounted below a scratch directory;
    btrfs: `@fleet-snapshots/<entry>@<tag>` on the top level), never from
    what happens to be mounted at its path; a snapshot a dead run left is
    replaced.
  - Content is only ever written into a new dataset or subvolume
    (`<location>.incoming`, a ZFS dataset with `acltype=posixacl`,
    `xattr=sa` and the entry's properties), which is then swapped in: the
    entry is quiesced (its units, triggers and mount blocked by a drop-in
    in `/run` asserting the absence of `/run/fleet-state/<entry>.blocked`,
    which also records the boot; triggers stopped, then the units and
    instances running by then, then the mount unit, which takes nested
    entries along), the current location renamed to
    `<location>.aside-<time>` (unique, auto-snapshots off), the new one
    renamed into place, its ZFS properties set, and of these units and
    whatever needs them (`systemctl list-dependencies --reverse`) what
    stopped is started again, except what other entries still block and a
    socket's spawned instances. Records and blocks add up over repeated
    stops. HUP, INT and TERM are held off during a swap, SIGPIPE is
    ignored throughout (a lost admin connection fails writes, not the
    run), and a cleanup puts the old location back and resumes if the swap
    fails. The renames hold `/run/fleet-state.swap.lock`, which the state
    module's creation script and activation snippet take too. `restore`,
    `rollback` and the moves' `place` all work this way.
  - `backup` labels each rustic snapshot with the entry, records the host,
    tags `fleet-entry:`, `fleet-service:` and `fleet-root:<uid>:<gid>:<mode>`
    (rustic keeps no metadata of an `--as-path` root; restores apply it),
    and prints `<entry> <id>`; `--all` prunes even when an entry failed and
    writes the metrics (the last success kept when not). Steps that may
    fail alone run in a subshell outside any condition, so errexit holds
    in them. "Latest" is the newest by host and label, whatever the path.
  - Moves: `send` streams a snapshot as a tar (numeric owners, ACLs,
    xattrs, sparse files), of a declared entry or, by kind, of one left
    behind, and refuses entries with datasets or subvolumes below them;
    `receive` untars into `<location>.incoming` (anything tar reports
    fails it) and leaves it there; `place` renames it into place (swapped
    in if the host uses the entry already; refused if the location exists,
    unless `--replace`), `abort` removes it; `freeze` quiesces (unless a
    `stop` did) and sets the location read-only, with `--stopped` only if a
    stop in this boot kept the entry stopped all along; `thaw` undoes it;
    `drop` destroys the location of an entry the host no longer declares,
    with its snapshots and blocks, never anything below it. `access`
    writes a kind's repository table as JSON (with `password-file`), the
    host's name and the credential files as a tar; `receive --from-backup`
    unpacks that into a `0700` directory below the scratch space, refuses
    anything but plain files, settings with commands or hooks, and
    credential paths used other than as whole values, points those into
    the directory, writes the TOML profile itself, and restores the
    snapshot named (or the newest of the recorded host) with
    `RUSTIC_NO_CACHE`.
  - Snapshots, mounts and scratch space are undone on any exit, signals
    included; one changing run at a time (`/run/fleet-state.lock`).
- `ftl-layers.sh` (hosts): environment from `modules/layers.nix`
  (`FTL_REPO_URL`, `FTL_LAYERS`, `FTL_STATE_DIR`, `FTL_PROFILE_DIR`,
  `FTL_VERIFY_MODE`, ...); installs each layer's `nixosLayers.<sys>.<l>` at
  the revision `ftl-layers.json` names, verifies the commit, restarts units of
  `units` layers.
- `ftl-pipeline.sh` (builder): environment from `modules/builder.nix`
  (`FTL_REPO_*`, `FTL_LANE*`, `FTL_SIGN_*`, `FTL_VERIFY_*`, `FTL_CACHE_*`,
  `FTL_PROMOTE`, ...); bumps the lane's inputs, builds `fleet.manifest`,
  pushes to the cache, pins red layers, fast-forwards the deployed branch.
- `ftl-status.sh` (hosts): `FTL_STATUS_URL`, `FTL_REPO_URL`.
- `ftl-cache-retention.sh` (builder): prunes the cache down to the closures
  of the last `keepGenerations` promoted generations per attribute, from the
  promotion log `ftl-pipeline` appends to.

## tests/

`tests/default.nix` is the suite for one set of inputs; `tests/stable` and
`tests/unstable` are the flakes that supply them (nixpkgs, home-manager,
sops-nix, comin, deploy-rs of the channel, ftl as a relative input). Unit
tests call each `mk*` on `tests/fixtures/layout`; `flake-isolated` and
`flake-full` go through `mkFlake`; `cli` and `generators` build what the CLI
uses; the VM tests cover the modules, layers, pipeline, cache, state and
secrets on real machines.
