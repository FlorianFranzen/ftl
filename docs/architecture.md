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

- Provides: the layer kinds (`packages`, `units`) and `normalize`, which maps
  the old names (`apps`, `services`) to them with a warning.
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
it, and produces every host-related output.

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
  - `peers`/`fleet.hosts` (every host's metadata: name, system, importance,
    layers, services, users, generators, keys, free-form data),
    `services`/`fleet.services`, `users`/`fleet.users`;
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
     (`hosts`, `services`, `users`, `self`) and, for one release, `peers`.
- Service modules: a module file is wrapped with `lib.setFunctionArgs` so
  that `service` (metadata, `role`, `dir`, `sopsFile`) is injected without
  the module system looking it up; `nixosServices.<s>` uses the same wrapper
  with the roles resolved lazily from `config.fleet.meta.host`.
- Stores: a host's `secrets.yaml` is for the host and the admins, its
  `identity.yaml` for the admins, a service's `secrets.yaml` for its hosts,
  the admins and the users listing it, a user's for that user. A host is a
  recipient by its `sops.age` if present, else by its `ssh.pub`.

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
- Shape of any generator: `{ pkgs }: { description; runtimeInputs; files;
  script; }`, where `files.<f> = { secret; store; }`.

### `lib/flake.nix` — `mkFlake`

- Reads: `src` (the repository), `inputs` (`nixpkgs` required;
  `home-manager`, `sops-nix` used when present), `name`, `repo`, `systems`,
  `layout` (folder names, `null` disables a family), `overlays`, `config`,
  `nixos.*`, `home.*`, `users`, `sops.extraRules`; anything else is
  deep-merged into the outputs.
- Provides: everything above as flake outputs, plus `fleet.sops` (stores +
  `extraRules`), `packages.<sys>.fleetl` and `generate-<g>`, `apps.<sys>.fleetl`,
  `checks.<sys>.fleet-sops`, and the former `ftlPeers`/`ftlManifest` with a
  warning.
- How: decides statically which families exist (so touching one output never
  evaluates another's nixpkgs), builds the integration module
  (`modules/flake.nix`) and hands the home results to `mkNixos`.

## modules/

Every module is importable on its own (`ftl.nixosModules.<name>`); `mkNixos`
imports all of them into every host and sets what it knows. Options live
under `fleet.*`; the old `ftl.*` names are mirrored by `compat`.

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
| `state` | `fleet.state.<name>` (`path`, `kind`, `units`, `service`, `backup`, `snapshots`, `zfs.properties`), `fleet.storage` (`btrfsDevice`, `zfsPool`, `zfsProperties`) | the `fleet-state` service creating subvolumes/datasets, one mount unit per entry, `RequiresMountsFor` on its units, an assertion that its units run with fixed uids or `DynamicUser` | no |
| `access` | `fleet.access.*` (`users` defaults to the host's fleet users, `sudo`, `knownHosts`, `initrdPort`); the `fleet` argument when present | accounts with keys and no password, sshd without passwords or root, sudo via pam_rssh, every host's keys in `known_hosts` | `users` and `knownHosts` need `fleet`; standalone, set `fleet.access.users` |
| `secrets` | `fleet.secrets.*` (`file` and `ageKeyFile` set by mkNixos); whether sops-nix's module is present | `sops.defaultSopsFile`, `sops.age.keyFile`, `sops.gnupg.sshKeyPaths = []` | `file` comes from mkNixos; settable by hand |
| `compat` | `options.fleet` | `options.ftl` mirroring every non-read-only option, definitions forwarded, one warning | no |
| `scripts` (a function, not a module) | `pkgs` | the packaged scripts: `fleetl` (+`ftl` alias), `ftl-layers`, `ftl-status`, `ftl-pipeline`, `ftl-cache-retention` | no |

## Standalone use

Each module can be imported on its own (`ftl.nixosModules.<name>`); what
`mkNixos` would set has to be set by hand then:

| module | set by hand |
|---|---|
| `layers` | `fleet.layers.installed.<l>.kind`, `fleet.layers.repo` |
| `access` | `fleet.access.users` (without the `fleet` argument there are no accounts and no known hosts) |
| `secrets` | `fleet.secrets.file`, `fleet.secrets.ageKeyFile` |
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

## Deprecations

Kept for one release, each with a warning: the `ftl.*` options (mirrored by
`compat`), the `ftlPeers` and `ftlManifest` outputs, `ftlArgs` on a
configuration, the `peers` module argument, the layer kinds `apps` and
`services` and the `services` attribute of a layer (`units`). ftl's own
consumer, `ftl-pipeline.sh`, reads `fleet.manifest` and falls back to
`ftlManifest` for repositories not yet moved.

## scripts/

- `fleetl.sh` (admin's machine, inside the repository): reads the flake's
  `fleet` output (`nix eval --json .#fleet.*`); `secrets sync` renders
  `.sops.yaml` from `fleet.sops` (SSH host keys through ssh-to-age) and
  re-keys the stores (`sops updatekeys`, needs the admin's key); `host
  generate` runs `packages.<sys>.generate-<g>` into a temporary directory,
  places public files, re-renders `.sops.yaml`, and writes secrets into the
  stores (a new store in one `sops --encrypt`; an existing one with `sops set`,
  which needs the admin's key); `host install` unpacks `identity.yaml` for
  nixos-anywhere. Temporary directories are `0700` and removed on return.
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
