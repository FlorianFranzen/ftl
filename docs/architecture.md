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
`sops.nix` (stores and recipients), `generators.nix`, `layers.nix`,
`smartcards.nix` (reader registration) and `caches.nix` (`fleet.caches`). Each
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
  `name`, `repo`, `root` (the repository root, for store paths), `smartcard`
  (the readers every host accepts).
- Provides:
  - `nixosConfigurations.<h>` (each with `fleetArgs`, the exact
    `nixosSystem` arguments, for VM tests), `nixosModules`, `nixosProfiles`,
    `nixosLayers.<sys>.<l>`, `nixosServices.<s>` (a service as a plain module);
  - `fleet.hosts` (every host's metadata: name, system, importance,
    layers, services, users, generators, smartcard, keys, free-form data),
    `services`/`fleet.services`, `users`/`fleet.users`, `keys`/`fleet.keys`
    (the fleet's `nixos/<name>.pub` files);
  - `sops.stores` (every store with its recipients: pgp and age keys, and the
    SSH host keys still to be converted), `generators` (what each makes) and
    `generatorPrograms system` (each as a program);
  - `caches` (`fleet.caches`: every `cache` a host.nix or service.nix
    announces, once per serving host, with its url, status url and keys);
  - `checks` (`nixos-<h>`, `nixos-layer-<l>`) and `manifestEntries`.
- How, in order:
  1. hosts and services are discovered and validated (unknown layers,
     services, generators, home configurations fail eagerly);
  2. a host's layers are its own plus its services'; its users are the admins
     plus whoever lists it or one of its services; its home per user comes
     from `user.nix` (`home` as a name or `{ default; <host>; }`); its
     `smartcard` is the fleet's readers (unless `fleetReaders = false`) plus
     its own, with a presence, or null when there are none. Reader ids are
     validated here, eagerly;
  3. every host gets: `sharedModules`, ftl's modules (`modules/*.nix`, all
     disabled by default), `nixos/modules`, its services' modules (wrapped so
     they receive the `service` argument), its own modules, the companions of
     its users' homes, and a meta module that sets `fleet.meta`,
     `fleet.layers.installed`, `fleet.secrets.file`/`shared`/`ageKeyFile`,
     `fleet.smartcard.{presence,readers}`, `fleet.agents.enable`,
     `fleet.meta.repoUrl` (the repository as a git URL, which
     `fleet.layers.repo` and `fleet.client.repo` default to),
     `networking.hostId` (from the name), `networking.domain` (from the
     fqdn), `fleet.nix.enable`, `fleet.client.enable` (when another host serves a
     cache), `networking.hostName` and `nixpkgs.hostPlatform`;
  4. the special arguments are `profiles`, `homes`, `static`, `fleet`
     (`hosts`, `services`, `users`, `keys`, `caches`, `self`), and
     `inputs` from mkFlake.
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

### Small shared pieces: `lib/repo.nix`, `lib/smartcard.nix`, `lib/keys.nix`, `lib/address.nix`, `lib/units.nix`

- `keys.nix`: reading the key files next to `host.nix` and `user.nix`
  (`lines`: one entry per line, comments ignored; `readKey`: the first entry,
  or a whole PEM file).
- `address.nix`: how a host is reached (`addressOf`: its fqdn, else its name)
  and the names its key is known under (`namesOf`), for fleet.access's ssh
  blocks, mkDeploy and the caches; the key is pinned under the host's name
  everywhere (`HostKeyAlias`).
- `units.nix`: the sandboxing of ftl's own services and the `verify` option
  set (commit signature checks) the builder and the layer updater share.

- `repo` (`ftl.lib.repo { inherit lib; }`): `gitUrl`, the git URL of a
  repository given as a git URL or a flake reference (`github:`, `gitlab:`,
  `sourcehut:`, `git+…`). mkNixos uses it for `fleet.meta.repoUrl`, which
  `fleet.layers.repo` and `fleet.client.repo` default to and git fetches;
  `fleet.meta.repo` keeps the form given.
- `smartcard.nix`: what a reader registration is (presences, reader
  attributes, the USB id pattern, the text a reader is shown with), shared
  by `lib/nixos/smartcards.nix`, `modules/smartcard.nix` and
  `lib/agents.nix`.

### `lib/agents.nix` — `ftl.lib.agents`

- Reads: `{ lib }`, then the fleet's metadata: `hosts` (`fleet.hosts`),
  `services`, `users`, `caches`, `name`, `repo`, and `extra` (strings or
  files appended).
- Provides: `fleet` (the repository's `AGENTS.md`, `fleet.agents`), `host`
  (one host's part, the head of its `/etc/AGENTS.md`), `rules presence`
  (the hardware key rules for `attended`, `headless` or no reader),
  `pushCommand host` (the `nix copy` through `sudo nix-daemon`).
- How: plain string rendering of metadata, never of an evaluated
  configuration, so the file is cheap to produce and stable for the
  `fleet-agents` check. The rules are mind-the-gap's and nix-piv's practice:
  - PIN tries are scarce, and a provisioned card's PUK is blocked;
  - a touch needs a person;
  - scdaemon holds every reader;
  - a card under a running agent must not be opened exclusively.

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
  `sshOpts`, `exclude`, `sudoCopy` (default: `sshUser` is not root; the
  closure is copied as root through sudo, since the hosts trust nobody else).
- Provides: the `deploy` output (`nodes`, `sshUser`) and `knownHosts`, a file
  with every host's `ssh.pub`; nodes with a key are pinned to it
  (`HostKeyAlias`, `UserKnownHostsFile`, `StrictHostKeyChecking=yes`).

### `lib/generators/*.nix`

- `host-keys`: SSH host key and initrd key (`ssh.pub`, `initrd.pub`; private
  halves in `identity.yaml`). On every host by default.
- `age-key`: a dedicated age key (`sops.age`; key in `identity.yaml`).
- `fleet-ca` (scope fleet): an ECDSA P-256 CA, ten years
  (`nixos/fleet-ca.pub`; key in `nixos/identity.yaml`, admins only).
- `wireguard`: a WireGuard key pair (`wireguard.pub`, the private key in the
  host's store).
- `host-tls`: an ECDSA P-256 certificate for `DNS:<host>` and what the
  host's `tls.names` and `tls.addresses` list (as DNS and IP names), server
  and client use, five years, signed by `fleet-ca` (its inputs: the CA's
  certificate and key, made first if missing): `tls.pub` next to
  `host.nix`, the key in the host's store as `host-tls/tls.key`.
- Shape of any generator: `{ pkgs }: { description; scope; inputs;
  runtimeInputs; files; script; }`, where `files.<f> = { secret; store; }`.
  The program is run with `HOST` (the host's name, `fleet` for the fleet)
  and `HOST_JSON` (a file with `fleet.hosts.<h>`, `{}` for the fleet).
  `scope` is `host` (per host, listed in `host.nix`, files next to it and in
  its stores) or `fleet` (once, files in `nixos/` and in `nixos/secrets.yaml`
  or `nixos/identity.yaml`; `nixos/<name>.pub` is `fleet.keys.<name>`).
  `inputs` lists files of other generators (`<generator>/<file>`) the script
  reads under `$in`; `mkNixos` checks that they exist, are declared, do not
  loop, and that a fleet generator reads fleet files only. The program is
  `generate-<name> <out> [<in>]`.

### `lib/flake.nix` — `mkFlake`

- Reads: `src` (the repository), `inputs` (`nixpkgs` required;
  `home-manager`, `sops-nix`, `disko` and `deploy-rs` used when present), `name`, `repo`, `systems`,
  `layout` (folder names, `null` disables a family), `overlays`, `config`,
  `nixos.*`, `home.*`, `users`, `sops.extraRules`, `smartcard` (readers for
  every host), `agents.extra`, `deploy` (mkDeploy's settings, with a
  deploy-rs input; a ready output with `nodes` passes through), and
  `nixos.inputModules`/`nixos.exportInputs`; anything else is deep-merged into
  the outputs. home-manager's module is imported into every host when there
  are homes; sops-nix's and disko's when they are paths, which the module
  system imports once even if the fleet lists them too (`inputModules =
  false` turns these two off); `inputs` is a special argument.
- Provides: everything above as flake outputs, plus `fleet.sops` (stores +
  `extraRules`), `fleet.caches`, `fleet.agents` (the repository's AGENTS.md),
  `packages.<sys>.fleetl` and `generate-<g>`, `apps.<sys>.fleetl`,
  `checks.<sys>.fleet-sops` and `checks.<sys>.fleet-agents` (the committed
  file against what the sync command would write; each exists only once the
  repository has the file), `deploy` and deploy-rs' checks (with `deploy`),
  `devShells.<sys>.default` (fleetl, sops, ssh-to-age, age, deploy-rs).
- How: decides statically which families exist (so touching one output never
  evaluates another's nixpkgs), builds the integration module
  (`modules/flake.nix`) and hands the home results to `mkNixos`.

## modules/

Every module of `modules/all.nix` is importable on its own
(`ftl.nixosModules.<name>`, named after its file; `nixosModules.default` is
all of them); `mkNixos` imports all of them into every host and sets what it
knows. `meta.nix` and `dirs.nix` are imported by the modules that need them,
`flake.nix` (the integration module) and `scripts.nix` (a function) are not
modules of their own. Options live under `fleet.*`.

| module | reads | provides | depends on being loaded by mkNixos? |
|---|---|---|---|
| `meta` | — | `fleet.meta` (`environment`, `repo`, `repoUrl`, `host`, `attr`, `importance`, `system`, `layers`, `services`, `users`) | set by mkNixos; standalone it is empty |
| `dirs` | — | `fleet.rootDir` (`/var/lib/ftl`; `state/`, `status/`, `cache/`, `keys/` below it) | no |
| `flake` (injected, not exported) | `inputs`, overlays, nixpkgs config, home results | `nixpkgs.overlays`/`config`, flake registry for `exportInputs`, `NIX_PATH` for nixpkgs, `system.configurationRevision`, home-manager wiring | mkFlake only |
| `builder` | `fleet.builder.*` (repos and lanes, signing, verify, cache, remote builders), `fleet.rootDir`, the host's own `fleet.caches` entry (`cache.publicKey`) | the `ftl-pipeline-<repo>-<lane>` services and timers, the `ftl` user, directories, nix-daemon signing | no |
| `cache` | `fleet.cache.*`, `fleet.rootDir` | nginx serving `cache/` and `status/` | no |
| `client` | `fleet.client.*`; `fleet.caches` from the `fleet` argument when present | substituters (its own and the fleet's caches but the host's own), gc when `gc.automatic`, `ftl-status` pointed at a fleet cache's status page | `enable` comes from mkNixos when another host serves a cache; standalone, set `substituters` |
| `layers` | `fleet.layers.*` (`installed` set by mkNixos, `repo`, `verify`, timer) | `environment.profiles` for packages layers, a systemd generator linking units layers, `ftl-layers` and its update service and timer, `fleet.layers.hook` | `installed` comes from mkNixos; settable by hand |
| `comin` | `fleet.comin.*`, whether comin's and lanzaboote's modules are present | `services.comin.remotes` (the fleet's repository at `fleet.comin.branch`), `services.comin.postDeploymentCommand` = the hook (system profile sync for lanzaboote, then layer update) | no |
| `state` | `fleet.state.<name>` (`path`, `kind`, `units`, `service`, `backup`, `snapshots`, `zfs.properties`), `fleet.storage` (`btrfsDevice`, `zfsPool`, `zfsProperties`, `tool.enable`), `fleet.backup.enable` | the `fleet-state` service creating subvolumes/datasets (wanted by `local-fs.target`, `Before=` the mounts, none of which depends on it: a mount unit's text changes only with its storage, see `docs/state-mounts.md`), one mount unit per entry, `RequiresMountsFor` on its units, assertions (fixed uids or `DynamicUser`, entry names); the `fleet-state` tool and `/etc/fleet-state/state.json` (backend, device or pool, host, entries with ZFS properties) where there are entries, a ZFS pool or backups; an activation snippet lifting the blocks of entries no longer declared | no |
| `backup` | `fleet.backup.*` (`repositories.<kind>`, `passwordFile`, `credentialFiles`, `packages`, `schedule`, `retention`, `metrics.textfileDir`), `fleet.state` | `/etc/rustic/<kind>.toml`, `/etc/fleet-state/backup.json`, the `fleet-backup` service and timer (`fleet-state backup --all`), `fleet-backup-init` | no |
| `access` | `fleet.access.*` (`users` defaults to the host's fleet users, `sudo`, `knownHosts`, `sshConfig`, `localPasswords`, `initrd.{enable,port,hostKey}`); the `fleet` argument when present | accounts with keys (and `shell`/`description` from user.nix) and no password unless `localPasswords`, sshd without passwords or root, sudo via pam_rssh, every host's keys in `known_hosts`, a block per fleet host in `/etc/ssh/ssh_config` (agent forwarded for the host's accounts only, multiplexed; `<host>-unlock` for the initrd), the initrd's sshd for unlocking with the admins' keys (DHCP in the initrd without fleet.network) | `users`, `knownHosts` and the ssh blocks need `fleet`; standalone, set `fleet.access.users` |
| `secrets` | `fleet.secrets.*` (`file`, `shared` and `ageKeyFile` set by mkNixos); whether sops-nix's module is present | `sops.defaultSopsFile`, `sops.age.keyFile`, `sops.gnupg.sshKeyPaths = []`; `shared` for modules to point a secret at | `file` comes from mkNixos; settable by hand |
| `smartcard` | `fleet.smartcard.*` (`readers` and `presence` set by mkNixos from the metadata, `scdaemon`, `touchDetector`, `agent`); whether nix-piv's `services.piv-agent` and `programs.yubikey-touch-detector` exist | pcscd bound to the registered readers (udev `PCSCLITE_IGNORE`), scdaemon through pcscd, the touch detector (attended), nix-piv's agent with its group socket and the builder wired to it (headless) | `readers` comes from mkNixos; settable by hand |
| `network` | `fleet.network.*` (`uplink` defaults to the host's `network` block, `ownNames`) | systemd-networkd's `10-wan` from the block (checked for `mac`/`interface` and `ipv4`), the host's names on its addresses, the same uplink in the initrd wherever the initrd brings up networking | `uplink` comes from the `fleet` argument; settable by hand |
| `agents` | `fleet.agents.*` (`enable` set by mkNixos, `sections`); the `fleet` argument when present | `/etc/AGENTS.md`: the host's part of the repository's file (lib/agents.nix) and the sections other modules add (smartcard, access, builder, layers, comin, client) | without `fleet`, only the sections |
| `nix` | `fleet.nix.*` (`enable` set by mkNixos, `trustWheel`) | flakes on, channels off; nobody but root trusted unless `trustWheel` (unsigned closures arrive through `sudo nix-daemon`, see `tests/push.nix`) | no |
| `scripts` (a function, not a module) | `pkgs` | the packaged scripts: `fleetl` (+`ftl` alias), `ftl-layers`, `ftl-status`, `ftl-pipeline`, `ftl-cache-retention` | no |

## Standalone use

Each module can be imported on its own (`ftl.nixosModules.<name>`); what
`mkNixos` would set has to be set by hand then:

| module | set by hand |
|---|---|
| `layers` | `fleet.layers.installed.<l>.kind`, `fleet.layers.repo` |
| `access` | `fleet.access.users` (without the `fleet` argument there are no accounts, no known hosts and no ssh blocks) |
| `smartcard` | `fleet.smartcard.readers` (and `presence`) |
| `network` | `fleet.network.uplink` |
| `agents`, `nix` | `enable` |
| `secrets` | `fleet.secrets.file`, `fleet.secrets.shared`, `fleet.secrets.ageKeyFile` |
| `meta` | nothing; `fleet.meta.host` is null, which `nixosServices` tolerates (`service.role = []`) |
| `nixosServices.<s>` | the special arguments its modules use (`fleet`, `profiles`, ...); it is meant for other configurations of the same fleet |

`mkNixos` without `src` takes `hosts`, `layers`, `services`, `users` as
arguments; stores need `root`.

## Files and formats

- `host.nix`, `service.nix`, `user.nix`: plain attribute sets; the reserved
  attributes are, for hosts, `system importance layers services users
  generators smartcard` (plus `name`, `modules`, `dir`, never set by hand); for
  services `hosts roles layers` (plus `name`, `modules`, `dir`); for users
  `admin hosts services home uid groups shell description` (plus `name`,
  `keys`, `dir`). Everything else is free-form data and appears in
  `fleet.*`. Free-form attributes that ftl reads, so not to be used for
  anything else: on hosts `fqdn` (address, known_hosts name, domain),
  `network` (fleet.network), `tls` (the `host-tls` generator, through
  `HOST_JSON`) and `cache`; on services `cache` (`fleet.caches`).
- `smartcard` in `host.nix`: `{ presence ? "attended"; readers.<name> = {
  vendor; product?; serial?; port?; description?; }; fleetReaders ? true; }`
  or `null`; ids are four lower-case hex digits.
- `AGENTS.md` (repository root): written by `fleetl agents sync` from
  `fleet.agents`, compared by the `fleet-agents` check.
- `ftl-layers.json` (repository root): `{ "<layer>": "latest" | "<commit>" }`,
  written by the pipeline, read by `ftl-layers`.
- `fleet.manifest`: `{ name; repo; version = 1; attrs.<sys>.<check> = { kind
  = "nixos" | "layer" | "home"; host; layer; importance; configAttr;
  flakeAttr; } }`.
- `share/ftl-layer/meta.json` in a layer: `{ name; kind; units; }`.
- `<rootDir>/status/<name>.json` (builder): the lane's last run per check;
  `<stateDir>/<repo>/promoted.jsonl`: one line per promotion
  (`{ attr; rev; date; outPath; }`), the retention's input.
- `.sops.yaml`: generated; `creation_rules` with one `path_regex` per store,
  `key_groups` of `pgp` fingerprints and `age` recipients.

## scripts/

- `fleetl.sh` (admin's machine, inside the repository): reads the flake's
  `fleet` output (`nix eval --json .#fleet.*`); `check` evaluates each
  metadata file on its own, then the fleet, to name the file that breaks
  every output (fleet_json points to it when the fleet does not evaluate);
  `agents sync` writes
  `AGENTS.md` from `nix eval --raw .#fleet.agents`; `secrets sync` renders
  `.sops.yaml` from `fleet.sops` (SSH host keys through ssh-to-age) and
  re-keys the stores whose recipients, which sops keeps in the clear, differ from their rule (`sops updatekeys`, needs the admin's key);
  `secrets move` decrypts each key from every source (all must hold the
  same value, and the target must not have it), writes them to the target
  (`sops set`, or one `sops --encrypt` for a new store), decrypts them back
  to compare, and only then `sops unset`s them in the sources; `host
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
  `drop --force` of what it placed, once `place` succeeded) is recorded
  before the step, with the command that does it by hand, so a step that
  fails halfway is undone too, and what cannot be undone (a host out of
  reach) is printed. The deploy output (`sshUser`, the nodes' hostnames)
  is evaluated once per run, its absence meaning root and fqdn, its failure
  an error; ssh runs with `BatchMode` and a connect timeout. It refuses when the old host would
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
    renamed into place, its ZFS properties set, and what of the entry's
    scope stopped is started again. The scope is its units, triggers and
    mount and what needs them, walked along `RequiredBy`, `BoundBy`,
    `ConsistsOf`, `RequisiteOf` and `TriggeredBy` but never through a
    target; each entry records its own, first all of it that is active (so
    a failure halfway can be resumed), at the end what actually stopped.
    Records and blocks add up over repeated stops; on resume, what another
    entry still blocks, and what needs that, is handed to that entry's
    record (held by drop-in, so a blocked template holds its instances);
    a unit that needs a blocked unit only through a target is not seen as
    held. Active sockets, timers and paths in the scope are stopped too.
    HUP, INT and TERM are held during a swap and end the run after
    it, SIGPIPE is ignored throughout (a lost admin connection fails
    writes, not the run), and a cleanup registered before the swap puts
    the old location back and resumes (only the mounts with `--no-start`)
    if it fails. The renames hold `/run/fleet-state.swap.lock`, which the state
    module's creation script and activation snippet take too. `restore`,
    `rollback` and the moves' `place` all work this way.
  - `backup` labels each rustic snapshot with the entry, records the host,
    tags `fleet-entry:`, `fleet-service:` and `fleet-root:<uid>:<gid>:<mode>`
    (rustic keeps no metadata of an `--as-path` root; restores apply it,
    or for a backup without the tag the root's owner and mode as they are),
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
    stop in this boot kept the entry stopped all along, and writes
    `/var/lib/fleet-state/frozen/<entry>`, which the state module makes
    every unit of the entry assert absent (so the block survives reboots;
    the activation snippet removes markers of entries no longer declared);
    `thaw` undoes it; `drop` destroys the location of an entry the host no
    longer declares if it is frozen (marker, or `readonly` set locally /
    `ro` on btrfs), anything else only with `--force`, with its snapshots
    and blocks, never anything below it. `send` fails on anything tar
    reports but sockets, which it counts and leaves out. `size` reads ZFS's
    `referenced`, a btrfs qgroup when quotas are on, else counts with
    `du`. `access`
    writes a kind's repository table as JSON (with `password-file`), the
    host's name and the credential files as a tar; `receive --from-backup`
    unpacks that into a `0700` directory below the scratch space, refuses
    anything but plain files, settings with commands, hooks or nulls,
    repositories other than a local path, `opendal:` or `rest:` (rclone can
    run commands), and credential paths used other than as whole values, points those into
    the directory, writes the TOML profile itself, and restores the
    snapshot named (or the newest of the recorded host) with
    `RUSTIC_NO_CACHE`.
  - Snapshots, mounts and scratch space are undone on any exit, signals
    included; one changing run at a time (`/run/fleet-state.lock`).
- `lib/common.sh`: `notify` (ntfy) and `verify_commit` (FTL_VERIFY_*),
  put in front of `ftl-layers.sh` and `ftl-pipeline.sh` when they are
  packaged.
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
`flake-full` and `flake-wiring` go through `mkFlake`; `cli`, `agents` and
`generators` build what the CLI uses and checks; the VM tests cover the
modules, smartcard readers, pushing through sudo, layers, pipeline, cache,
state, backups, moves and secrets on real machines. `fast` is every check
but the VM tests (`vmTests` in `tests/default.nix` lists those).
