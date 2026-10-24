# ftl — fleet template library

ftl turns a repository with a standard folder layout into the flake outputs
of a fleet of NixOS hosts, and adds an optional fleet-update pipeline on top.
Every root folder is one output family, handled by its own `mk*` function that
only looks at that folder; `ftl.lib.mkFlake` runs on the repository root and
delegates to them. Each `mk*` function can also be used on its own.

| Root folder | Contents | Function | Flake outputs |
|---|---|---|---|
| `pkgs/` | `<name>/package.nix` (nixpkgs by-name shape; patches, scripts and `test.nix` next to it); optional `overlay.nix` (overrides, kernel modules, anything else; may use any other subfolder); optional `config.nix` (nixpkgs config, e.g. the unfree allow-list) | `mkPackages` | `overlays.default`, `packages.<sys>` (the `<name>/package.nix` packages available on that system), `legacyPackages.<sys>` (the full package set, shared by everything else) |
| `nixos/` | `hosts/<name>/*.nix` (modules of a host; `host.nix` is metadata `{ system; importance; layers; smartcard; … }`, not a module; further attributes are free-form host data); `modules/**.nix` (imported into every host); `profiles/**.nix` (opt-in via the `profiles` argument); `layers/<name>.nix` (layers, see below); `services/<name>/*.nix` (services, see below; `service.nix` is metadata `{ hosts; roles; layers; … }`) | `mkNixos` | `nixosConfigurations`, `nixosModules`, `nixosProfiles`, `nixosLayers.<sys>.<name>`, `nixosServices.<name>`, `fleet.hosts`, `fleet.services`; checks `nixos-<host>`, `nixos-layer-<name>` |
| `home/` | `modules/**.nix` (shared into every configuration); `profiles/<dir>/*.nix` (building blocks); `variants/*.nix` | `mkHome` | `homeModules`, `homeProfiles`, `homeConfigurations.<name>`, `legacyPackages.<sys>.homeConfigurations.<name>`; checks `home-<name>` |
| `static/` | any files and folders (wallpapers, complete config dirs, …) | `mkStatic` | none; available as the module argument `static` |
| `users/` | `<name>/user.nix` (metadata `{ admin; hosts; services; home; uid; groups; … }`, not a module); `ssh.pub` (SSH public keys, one per line); `sops.pgp`, `sops.age` (sops recipients, see below) | `mkUsers` | `fleet.users`; accounts on the hosts through `mkNixos` |

Names: `ftl` is the library, its input and whatever lives on disk (`ftl-layers`,
`ftl-layers.json`, `/var/lib/ftl`); `fleet` is every Nix namespace it owns: the
`fleet.*` NixOS options, the `fleet` output and the `fleet` module argument.

Missing folders are skipped. Folder names can be changed with
`layout.<family> = "dir"`, or a family disabled with `null`. Unrecognized
`mkFlake` arguments are deep-merged into the outputs.

[docs/architecture.md](docs/architecture.md) is the map of the code: what
each library function and module reads, provides and does.

## Conventions in detail

- **Package set.** Hosts, layers and homes all use nixpkgs plus `overlays`
  (argument) plus the `pkgs/` overlay, with `pkgs/config.nix`. Hosts get it
  through an injected integration module (`nixpkgs.overlays`, `nixpkgs.config`).
- **Hosts** are discovered from `nixos/hosts/*`. Every host also gets:
  - all `nixos/modules`;
  - ftl's own NixOS modules (all disabled by default);
  - an integration module: flake registry and `NIX_PATH` for `nixos.exportInputs`,
    `system.configurationRevision`, and the home-manager wiring when the
    `home-manager` input exists;
  - the specialArgs `profiles` (`nixos/profiles` merged over
    `nixos.extraProfiles`; local profiles win), `homes` (the home
    configurations as modules), `static` and `fleet`.
- **Fleet.** `fleet.hosts.<host>` is every host's metadata, as seen by every
  host (itself included), and `fleet.self` the host's own entry:
  `{ name; system; importance; layers; }` plus any free-form attributes of
  its `host.nix` (addresses, keys, roles, …). It is built from `host.nix`
  alone, never from an evaluated configuration, so modules may use it
  anywhere, including `imports`, to derive peers, scrape targets or DNS
  records from the host list. The same data is the `fleet.hosts` output, for
  anything outside a NixOS configuration (DNS, scripts, install tooling).

  ```nix
  # nixos/hosts/web/host.nix
  { importance = "required"; fqdn = "web.example.org"; wireguard.ip = "10.0.0.2"; }

  # nixos/modules/mesh.nix
  { fleet, lib, ... }: {
    networking.hosts = lib.mapAttrs' (_: h: lib.nameValuePair h.wireguard.ip [ h.name ])
      (lib.filterAttrs (_: h: h ? wireguard) fleet.hosts);
  }
  ```
- **Homes** are a matrix: `home.bases.<base> = [ profile dirs ]` times
  `home/variants/*`, named `<base>-<variant>`. A base includes only the
  *direct* `.nix` files of each listed dir. Configurations are built for every
  `home.systems` entry (`homeConfigurations` uses the first one).
- **Home and host.** A profile directory may carry a `nixos.nix` next to its
  home modules: the NixOS side that profile cannot do without (a PAM entry for
  the locker, portals, fonts). It is never part of the home; when a host gives
  a user a configuration built from that directory (`home` in `user.nix`), the
  host imports it. So adding a desktop home to a user adds exactly the system
  integration it needs, and a host with only terminal homes gets none of it.
- **Users.** `users/<name>/` is a person (or a deploy key): `user.nix` says
  where they have an account: an `admin` is on every host (or on the `hosts`
  listed, if any), in `wheel`, and may deploy; anyone else is on the `hosts`
  listed and on the hosts of the `services` listed. `home` names one of the home configurations
  (`<base>-<variant>`), installed through home-manager on those hosts, or is
  `{ default = …; <host> = …; }` for one per host. The
  access module (`fleet.access`, on as soon as a host has users) creates the
  accounts with the keys of `ssh.pub` and no password, turns off password and
  root login in sshd, lets admins sudo against their forwarded SSH agent
  (pam_rssh, with the same authorized keys), and puts every host's `ssh.pub`
  (and `initrd.pub`) into `known_hosts`. The policy settings (sshd, sudo,
  `users.mutableUsers = false`) are `mkDefault`; the accounts are not. Note
  that this switches on as soon as a host has a fleet user: the first
  `users/<name>/` makes every host key-only, which is the point, but worth
  knowing before the first deploy. A fleet with one person is
  `users/me/{user.nix,ssh.pub}` with `{ admin = true; }`.
- **Secrets** live next to what they belong to, one sops store each, and who
  can read a store follows from the layout:

  | store | readers |
  |---|---|
  | `nixos/secrets.yaml` (the fleet's, shared by every host) | every host, the admins |
  | `nixos/identity.yaml` (the fleet's private keys: a CA, …) | the admins |
  | `nixos/hosts/<h>/secrets.yaml` | the host, the admins |
  | `nixos/hosts/<h>/identity.yaml` (its private host keys, for installs) | the admins |
  | `nixos/services/<s>/secrets.yaml` | its hosts, the admins, the users listing the service |
  | `users/<u>/secrets.yaml` | that user |

  A host is a recipient through its SSH host key (`ssh.pub`, converted with
  ssh-to-age), or through the age recipient in a `sops.age` next to it, which
  then decrypts from `/var/lib/sops-nix/key.txt`; a user through `sops.pgp`
  and `sops.age`. The stores and their recipients are the `fleet.sops` output;
  `fleetl secrets sync` writes `.sops.yaml` from it (`sops.extraRules` in
  `mkFlake` appends rules of your own). When the flake has a `sops-nix` input,
  its module is imported into every host and `fleet.secrets` points it at the
  host's store and key (`file`) and at the fleet's shared store (`shared`); a
  service module reaches its own store as `service.sopsFile`.
- **Generators** make keys. `nixos/generators/<name>.nix` is
  `{ pkgs }: { files; script; runtimeInputs; scope; inputs; }`: the script
  writes the `files` into `$out`; public ones land next to `host.nix` (every
  `<name>.pub` there is `fleet.hosts.<h>.keys.<name>`), secret ones go into
  `secrets.yaml` as `<generator>/<file>` or, with `store = "identity"`, into
  `identity.yaml`. `host.nix` lists the generators a host uses (`generators`;
  `host-keys`, the SSH host and initrd keys, by default; `age-key` for a
  dedicated age key; `host-tls` for a TLS certificate for the host's name
  and what `tls.names` and `tls.addresses` in its `host.nix` list,
  good as server and client, signed by `fleet-ca`, the fleet's own CA,
  which is made once for the fleet: `nixos/fleet-ca.pub` for everyone,
  its key in `nixos/identity.yaml` for the admins). A generator with `scope = "fleet"` runs once for the
  whole fleet instead: its files land in `nixos/` (every `nixos/<name>.pub`
  is `fleet.keys.<name>`) and in the fleet's stores. `inputs` are files of
  other generators it reads, as `<generator>/<file>` under `$in`: a
  certificate signed by the fleet's CA, a key derived from the host's; what
  is missing is made first. `fleetl host init` runs a host's generators,
  `fleetl host generate <host>` and `fleetl fleet generate` run the ones
  whose files are missing later (`--force` for all of them), and
  `packages.<sys>.generate-<name>` is each one as a program.

  ```nix
  # nixos/generators/wireguard.nix
  { pkgs }: {
    runtimeInputs = [ pkgs.wireguard-tools ];
    files = { "wireguard.pub" = { }; private = { secret = true; }; };
    script = ''
      wg genkey > "$out/private"
      wg pubkey < "$out/private" > "$out/wireguard.pub"
    '';
  }
  ```
- **Smartcards.** A host's `smartcard` in `host.nix` registers the readers it
  may use, and mkFlake's `smartcard` registers readers for every host:

  ```nix
  # flake.nix: the admin's key works on every host
  smartcard.readers.yubikey = { vendor = "1050"; product = "0407"; };

  # nixos/hosts/pavlov/host.nix: a build server with its own card, nobody at it
  smartcard = {
    presence = "headless";               # "attended" (default): a person touches the key
    fleetReaders = false;                # not the fleet's readers, only its own
    readers.builder = { vendor = "1050"; port = "1-4"; };   # vendor, product, serial, port
  };
  ```

  Registering a reader is what turns `fleet.smartcard` on, and it then binds
  pcscd to exactly those readers. pcscd has no allow-list, so a udev rule
  marks every USB device `PCSCLITE_IGNORE` and the registered ones back.
  scdaemon goes through pcscd (`disable-ccid`), so gpg obeys the same filter.
  Only the smartcard (CCID) interface is filtered; FIDO2 and OTP are not.
  YubiKeys report no USB serial by default; `port` (the device's kernel name,
  `/sys/bus/usb/devices/<port>`) pins a key to a socket instead.
  - On an **attended** host, yubikey-touch-detector notifies the desktop
    session while a key waits.
  - A **headless** host's key is provisioned without touch (mind-the-gap
    `--policy once-pin`, or `nix-piv-provision`). It is used through
    [nix-piv](https://github.com/FlorianFranzen/nix-piv)'s `piv-agent`:
    add `nix-piv.nixosModules.agent` to `nixos.sharedModules`, and ftl
    enables it, opens its shared socket to the agent's group, and lets a
    `fleet.builder` on the host join that group and use the socket as
    `sshAuthSock`.
- **AGENTS.md.** `fleet.agents` is the repository's `AGENTS.md`, rendered from
  the metadata alone. It covers the layout, how to work in the repository,
  the hosts, services and users, the caches, and the rules for hardware keys:
  PIN tries, touch, scdaemon, a card under a running agent, and who is
  present where. `fleetl agents sync` writes it; once it is committed, the
  `fleet-agents` check fails while it is stale. `agents.extra` in mkFlake appends text or files of
  your own. Every host also gets `/etc/AGENTS.md`: its part of that file plus
  sections its modules add (`fleet.agents.sections`), covering how it is
  deployed, its layers, the pipeline, its readers and the agent socket.
- **ssh, caches, Nix.** Further settings follow from the same metadata:
  - The access module puts a block per fleet host into `/etc/ssh/ssh_config`
    (`fleet.access.sshConfig`), and a user's own `~/.ssh/config` still wins:
    - `ssh <host>` connects to its `fqdn` (or name) with the agent forwarded,
      since sudo authenticates against it;
    - connections are multiplexed for ten minutes, so a burst costs one PIN or
      touch;
    - `ssh <host>-unlock` reaches the initrd (root, port 2222, no agent) of
      hosts with an `initrd.pub`.
  - A binary cache is announced with
    `cache = { publicKeys = [ … ]; url?; port?; statusUrl?; }` in a `host.nix`
    (served by that host) or a `service.nix` (by each of its hosts). That is
    `fleet.caches`, and `fleet.client`, on wherever another host serves one,
    substitutes from them and points `ftl-status` at their status page.
  - `fleet.nix` sets flakes on and channels off. It trusts nobody but root:
    closures from the fleet's builder carry the cache signature the hosts
    trust. A closure built elsewhere is pushed through sudo, authenticated by
    the forwarded agent (and a touch, with such a key):

    ```
    nix copy --no-check-sigs --to 'ssh-ng://<host>?remote-program=sudo%20nix-daemon' <path>
    ```

    After that, `nixos-rebuild --target-host <host> --sudo` or deploy-rs find
    the paths in place. `fleet.nix.trustWheel` puts `@wheel` back in
    trusted-users. That makes every admin root-equivalent toward the store
    without authenticating.
- **`fleetl`** (alias `ftl`; `nix run .#fleetl -- …`, or `packages.<sys>.fleetl`
  in a dev shell) is the fleet from the admin's machine, inside the repository:

  ```
  fleetl secrets sync [--check]   .sops.yaml from the layout; re-key the stores
                                  whose recipients are not the rules' (--rekey: all)
  fleetl secrets edit <store>     sops on a store
  fleetl secrets move --to <store> --from <store>... <key>...
                                  keys into another store (a service's, say),
                                  only if every source holds the same value;
                                  written there and checked, then removed from
                                  the sources (needs the admin's key)
  fleetl agents sync [--check]    AGENTS.md from the fleet's metadata
  fleetl host init <name>         a host folder, its generators run (--age-key:
                                  a dedicated age key too)
  fleetl host generate <name>     the host's generators whose files are missing
  fleetl host install <name> <target> [--disk-key] [-- <nixos-anywhere args>]
                                  nixos-anywhere with the identity in place
  fleetl host exec <name>|all [--user <u>] [--] <command...>
                                  a command on a host, or on every host that is
                                  not ignored, pinned to its ssh.pub
  fleetl host show | service show | user show <name>
  fleetl service move <service> <to> [--from <host>] [--via stream|backup]
                     [--without-data] [--no-backup] [--yes]
                                  the service and its state to another host
  fleetl state list | snapshots <host> [<entry>]
  fleetl state init <host>        create the host's backup repositories, once
  fleetl state size | stop | start <host> <entry>...
  fleetl state backup <host> --all|<entry>...
  fleetl state restore <host> <entry> [--snapshot <id>] [--from-host <h>] [--no-start]
  fleetl state rollback <host> <entry> [<aside>]
  fleetl state discard <host> <aside>
  fleetl state thaw <host> <entry>...
  fleetl state drop <host> <entry> <kind>
  fleetl state copy <from> <to> <entry> <kind>
                                  fleet-state on the host, as root (sudo through
                                  the forwarded agent unless the login is root)
  fleetl fleet generate [--force] [<generator>...]
                                  the fleet's generators whose files are missing
  fleetl fleet show               the fleet: hosts, services, users, keys, stores
  fleetl user init <name> [--admin] [--ssh-key <file>] [--pgp <fpr>] [--age <recipient>]
  ```

  Once the files are committed, the check `fleet-sops` fails when
  `.sops.yaml` is not what `secrets sync` would write, and `fleet-agents`
  when `AGENTS.md` is not what `agents sync` would write. A repository
  without the file has no such check.
- **Deploying** with deploy-rs: `ftl.lib.mkDeploy { hosts = self.fleet.hosts;
  inherit (self) nixosConfigurations; deploy = inputs.deploy-rs; sshUser = "admin"; }`
  is the `deploy` output, one node per host, reached by its `fqdn` (or
  `address = h: …`) and checked against its `ssh.pub`, so stale DNS or
  known_hosts entries never get in the way. An `sshUser` other than root copies
  the closure through sudo (`sudoCopy`, on by default then), since the hosts
  trust nobody but root. This needs a deploy-rs with `sudoCopy` support
  (`ssh://<sshUser>@<host>?remote-program=sudo -u root nix-store`); older ones
  ignore the setting. Until then, push with `nix copy` through
  `sudo nix-daemon` first (see `fleet.nix` below). comin (`fleet.comin`) is the
  pull-based alternative.
- **Static files** are a lookup, not an installer. A file's key is its name
  without its last extension: `static/wallpapers/nixish-dark.png` becomes
  `static.wallpapers.nixish-dark`. Every directory also has an `outPath`, so
  `static.emacs` can be used directly as a path (`doomDir = static.emacs;`). It
  copies to the same store path as the equivalent path literal. Reference
  repository files through `static` rather than with relative paths that cross
  folders.

## Example

```nix
outputs = { self, nixpkgs, ftl, home-manager, ... }@inputs:
  ftl.lib.mkFlake {
    src = ./.;
    inherit inputs;
    name = "myenv";
    repo = "github:me/infra";       # or a git URL; git fetches use its git URL
    overlays = [ ];
    nixos = {
      specialArgs.username = "me";
      sharedModules = [ ];            # upstream modules, e.g. comin, lanzaboote
      extraProfiles.hardware = nixos-hardware.nixosModules;
      exportInputs = [ "self" "nixpkgs" "home-manager" ];
    };
    home = {
      bases = {
        terminal = [ "terminal" ];
        desktop = [ "terminal" "desktop" ];
      };
      username = "me";
    };
  };
```

## Fleet: services, layers, pipeline, cache

Three things live under `nixos/` besides hosts, and they are easy to mix up:

| | unit of | delivered by |
|---|---|---|
| **service** (`nixos/services/<name>/`) | placement: where something runs, with its data, secrets and state | the hosts' NixOS configurations: modules, rebuilt with the system |
| **layer** (`nixos/layers/<name>.nix`) | independent delivery: an update without a system rebuild | a Nix profile under `/nix/var/nix/profiles/layers/` |
| **profile** (`nixos/profiles/**.nix`) | reuse: a building block | imported by hosts and services through `profiles` |

- **Services** are folders of NixOS modules with a `service.nix` that says where
  they run:

  ```nix
  # nixos/services/mail/service.nix
  { hosts = [ "darwin" ]; names = [ "mail.example.org" ]; }

  # nixos/services/tang/service.nix: two sides of one service
  { roles.server.hosts = [ "a" "b" ]; roles.client.hosts = [ "c" ]; layers = [ "tools" ]; }
  ```

  `hosts` is short for `roles.default.hosts`. Moving a service is editing that
  line. Its modules are imported on its hosts only and get the `service`
  argument: the metadata (`name`, `hosts`, `roles`, `layers`, free-form data
  such as `names` above), `role` (this host's roles in it) and `dir` (its
  folder). Layers a service lists are installed on its hosts. Every host sees
  every service as `fleet.services.<name>`, and its own as `fleet.self.services`;
  `nixosServices.<name>` is the service as a plain module for another
  configuration of the fleet (a VM test built from a host's `fleetArgs`, say):
  it needs the same special arguments, and `service.role` is empty unless
  that configuration sets `fleet.meta.host`. `home.nix` in a service folder is
  reserved for its home side.
- **State** (`fleet.state.<name> = { path; kind; units; service; }`) is what a
  host keeps: each entry is a btrfs subvolume (`@apps/<name>`, `@data/<name>` on
  `fleet.storage.btrfsDevice`) or ZFS dataset (`<pool>/apps/<name>`, on
  `fleet.storage.zfsPool`), created on demand and mounted at `path` by a mount
  unit its `units` wait for, so the root filesystem stays disposable. The
  mount units name nothing but the storage (the setup service is ordered
  before them, but none depends on it), so a deploy only unmounts an entry
  when its storage changed, and restarting the setup unmounts nothing (see
  `docs/state-mounts.md` for why). `kind =
  "state"` is small and precious (snapshotted, backed up by default), `"data"`
  bulk and re-obtainable. An entry declared by a service module with `service =
  service.name` moves with the service: its declaration, and its contents
  (`fleetl service show` lists them). A unit of an entry must run with a fixed
  uid or as `DynamicUser`, or evaluation fails: dynamically allocated uids
  live on the root filesystem and would not survive a reinstall. On the
  host, `fleet-state` (as root) lists the entries and backs them up.
- **Backups** (`fleet.backup`) put every entry with `backup = true` into a
  rustic repository per kind (`repositories.state`, `repositories.data`),
  daily by default and pruned by `retention`. Each backup is taken from a
  snapshot of the entry's dataset or subvolume, so services keep running,
  and is recorded under the entry's real path, with the entry as label, the
  host as host and `fleet-entry:<entry>`, `fleet-service:<service>` as tags.
  Repositories are only created by `fleet-state init` (or the
  `fleet-backup-init` service), never by a backup. `/etc/rustic/<kind>.toml`
  makes them usable by hand (`rustic -P state snapshots`);
  `metrics.textfileDir` writes `fleet_backup_last_success_timestamp_seconds`
  and `fleet_backup_snapshots{kind}` for node_exporter.

  A restore puts an entry back: `fleetl state restore <host> <entry>
  [--snapshot <id>]` (on the host: `fleet-state restore`) restores the
  latest backup of the entry by this host (or the one named), with the uids
  and gids as they were and the owner and mode of its top directory (a
  `fleet-root:` tag of the backup, as rustic does not keep them), into a new
  dataset or subvolume next to the entry while it keeps running, then swaps
  it in: the entry's units, triggers and mount are blocked from starting
  and stopped, along with whatever needs them, the current dataset or
  subvolume is renamed aside (`<location>.aside-<time>`) and the restored
  one takes its name; then what stopped is started again. A lost
  connection does not end a swap, a signal ends it only once it is done,
  and a swap that fails puts the entry back as it was. An entry mounted inside another stays as it is.
  `fleetl state rollback` swaps a copy kept aside back in (the current one
  goes aside in turn), `fleetl state discard` destroys one, `fleetl state
  list` shows them. `stop` and `start` do the unit part alone: a stopped
  entry's units refuse to start until `start` (a drop-in in `/run`, so a
  reboot lifts it, as does a deploy without the entry), and `start` starts
  what `stop` stopped, however often it was stopped; what another stopped
  entry still holds (a unit two entries share, a service needing a unit of
  the other) starts with that entry. Datasets and
  subvolumes below an entry are not part of its snapshots: backups warn
  about them, moves refuse, nothing destroys them.
- **Moving a service** with its state is one command, then a commit and two
  deploys:

  ```
  fleetl service move web darwin          # from the one host web runs on
  git commit -am 'web: on darwin'         # then deploy darwin, then the old host
  fleetl state drop amphi web state       # once both are deployed and darwin runs it well
  ```

  It checks where the service runs, which entries are its (`service =
  service.name`), that the target has `fleet-state` and none of them, shows
  their sizes and asks; one move per repository at a time. Then it replaces
  the old host by the new one in `service.nix`, in `hosts` and every role,
  and refuses if evaluating it shows any other change, or if the old host
  would have no `fleet-state` once deployed (nothing could drop what the
  move leaves there). On the old host the entries are stopped (and
  blocked), the ones backed up get a last backup, each entry is streamed
  from a snapshot into `<location>.incoming` on the target (through the
  admin's machine, as a tar with numeric owners, ACLs and xattrs; the
  target's datasets have POSIX ACLs and SA xattrs; anything tar cannot read
  or set fails the move, except sockets, which are not carried and are made
  anew by whoever listens) and placed only once both ends finished, and
  the old copies are frozen: read-only and blocked, and only if they stayed
  stopped since (no reboot, no start meanwhile). A frozen copy stays
  blocked across reboots: every entry's units assert the absence of
  `/var/lib/fleet-state/frozen/<entry>`, which freeze writes and a deploy
  without the entry removes. Last, `secrets sync` re-keys the service's
  store for the target. Until then every step is undone on a failure, a
  step that failed halfway included, as far as the hosts can be reached:
  `service.nix` back, what this move placed on the target dropped (never
  what was there before), the old copies thawed and started again. What
  could not be undone is printed with the commands that do it by hand. The
  hosts are reached as the deploy output says, evaluated once, with ssh in
  batch mode, so that a lost host fails the move rather than hanging it. The service is down from the stop until the
  target runs the new configuration; the target's datasets are there
  before its deploy, so it starts on its state, never on an empty one.
  `--from` picks the host of a service on several, `--no-backup` skips the
  last backup, `--without-data` leaves the `data` entries on the old host,
  unfrozen and out of the drop list: `fleetl state copy <from> <to> <entry>
  data` brings one over later (swapped in on the target), and `drop
  --force` removes it once the old host is deployed. `drop` only takes the
  frozen copy a move left on a host that no longer declares the entry;
  anything else (a copy just placed, a mistyped host) only with `--force`.

  While an entry is stopped or frozen, a deploy of that host reports its
  units as failed: they refuse to start, by design, until `start`, `thaw`
  or the deploy that takes the entry away.

  `--via backup` takes the backed-up entries through the backup instead of
  the admin's machine: the target restores exactly the snapshot the last
  backup made, straight from the old host's repository. The old host sends
  its repository settings as data (the `[repository]` table, never a
  profile: settings carrying commands or hooks are refused), the host name
  its backups are recorded under, and the files they read
  (`fleet.backup.passwordFile`, `credentialFiles`); only a local path, an
  `opendal:` or a `rest:` repository is handed over; the target writes its
  own profile pointing into a `0700` directory in `/run`, restores with no
  rustic cache, and removes the directory. The credentials pass the
  admin's machine in the pipe, and while the restore runs the target's root
  could read and change the old host's repository; with per-host
  repositories that is the old host's backup history. The target needs the
  repository's transport in its PATH (`ssh` for sftp) and its host key.
  Entries that are not backed up are streamed as before.

  The target needs `fleet-state` before it has entries of its own; it is
  there with any entry, a ZFS pool or backups, else set
  `fleet.storage.tool.enable`.
- **Layers** (`nixos/layers/<name>.nix`, `{ kind; packages = pkgs: [ … ]; units; }`)
  are independently versioned Nix profiles under
  `/nix/var/nix/profiles/layers/<name>`, combined with the base system at
  runtime:
  - `kind = "packages"`: added via `environment.profiles`;
  - `kind = "units"`: unit files linked in by a systemd generator, so an
    update needs only `daemon-reload` and a restart.

  Hosts list their layers in `host.nix`. Each layer's revision comes from
  `ftl-layers.json`: `latest`, or the commit it last built at. A host with
  layers needs `fleet.layers.repo`, which defaults to `mkFlake`'s `repo` as a
  git URL (`github:me/infra` becomes `https://github.com/me/infra.git`;
  `ftl.lib.repo` does the conversion).
- **`fleet.builder`** (pipeline) verifies the signature on the branch tip, bumps
  flake inputs per lane, builds everything in `fleet.manifest` with
  `nix-fast-build`, pushes the (daemon-signed) results into a `file://` cache,
  and fast-forwards the deployed branch with a signed lock-bump commit once
  every required host builds. A red layer is pinned in `ftl-layers.json`, never
  blocking. Lanes of one repo run one at a time.
- **`fleet.cache`** serves that cache and the status JSON. It is plain HTTP on
  all interfaces; NAR signatures carry the trust, and the status pages list
  the fleet's hosts, so `openFirewall` is off by default.
- **Directories:** everything lives under `fleet.rootDir` (default
  `/var/lib/ftl`, owned by root, 0755):
  - `state/`: private pipeline state, `ftl` only;
  - `status/` and `cache/`: published by nginx;
  - `keys/`: owned by root, readable by group `ftl`; holds the keys the
    pipeline user needs (deploy key, commit signing key).

  Each path has its own option, e.g. `fleet.builder.cache.dir`. A typical setup
  mounts a large disk at `<rootDir>/cache` and leaves the rest on the system
  disk.
- **`fleet.layers`** installs the layers on hosts, verifies the target commit, and
  provides `ftl-layers update | list | rollback <name>`.
- **`fleet.comin`** connects [comin](https://github.com/nlewo/comin), which deploys
  the base system. Its post-deploy hook updates the layers; on lanzaboote hosts
  it also mirrors comin's generation into the `system` profile.
- **`fleet.client`** provides substituters (the fleet's caches among them), gc
  defaults and `ftl-status`.

### Trust model

The builder is the fleet's trust anchor: whatever it signs, every host
deploys. Keep these in mind when setting it up.

- **The pipeline user evaluates untrusted code.** Anyone who can land a commit
  on the branch, or publish to a flake input that a lane bumps, controls what
  `nix flake update` fetches and what gets evaluated and built. A flake input
  such as `path:/some/dir` copies any directory the `ftl` user can read into
  the world-readable store, so no secret that must stay secret may be readable
  by `ftl`. Hence:
  - the NAR signing key (`fleet.builder.cache.secretKeyFile`) is `0400 root` and
    used by nix-daemon (`secret-key-files`), which signs every locally built
    path. The pipeline never reads it, and pushes nothing while no key is
    configured. The file must exist before the configuration is activated;
    nix-daemon fails local builds while it is missing;
  - the deploy key and the commit signing key are used by `ftl` itself, so
    they are exposed to the same risk. Prefer keys that cannot be read at all:
    a smartcard behind an ssh-agent (`fleet.builder.sshAuthSock`, with
    `deployKeyFile = null` and `signing.key = "key::<public key>"`), or a
    smartcard-backed OpenPGP key (`signing.format = "openpgp"`,
    `signing.gnupgHome`); and a deploy key the forge restricts to fast-forwards
    of the deployed branch. With an agent, code running as `ftl` can still ask
    for signatures while it runs, but cannot take the key away;
  - keys nix-daemon cannot hold (e.g. on a smartcard) sign the cache through
    `fleet.builder.cache.signer.command` after each push, ideally a command that
    hands the work to a root service (e.g. nix-piv's `piv-cache-signer`) so the
    card PIN stays out of `ftl`'s reach. It can run next to `secretKeyFile`;
    paths then carry both signatures. Remote builders without `sshKey` use the
    agent too.
- **The builder's signature says "built green on top of a trusted tip".**
  With `fleet.builder.verify` the pipeline refuses to build on a branch tip that
  is not signed by a listed key (humans, CI, and the builder itself for its own
  previous promotion). Without it, any write access to the forge yields a
  builder-signed deployment. Lanes that bump third-party inputs extend the
  same trust to those inputs' maintainers.
- **Hosts must verify too.** comin checks the deployed commit when
  `services.comin.gpgPublicKeyPaths` or `services.comin.sshAllowedSignersPath`
  is set; `fleet.layers.verify` covers manual and timer-driven layer updates.
  Without these, hosts deploy whatever the branch points at.
- **Public surfaces.** The status JSON is public: it names hosts, attrs and
  store paths. Credentials embedded in a repo URL are stripped before
  publishing, but the URL is still visible to local users via `systemctl
  show`; use SSH URLs with `deployKeyFile` instead of tokens. ntfy
  notifications carry attr names and evaluation error excerpts; use a private
  topic. Pin the forge's SSH host key with `fleet.builder.knownHostsFile` or
  `programs.ssh.knownHosts`; unknown hosts are refused, not trusted on first
  use. Remote builders require `publicHostKey`.

## Tests

The library flake has no inputs. The test suite lives in two flakes with the
same checks, `tests/stable` (nixpkgs `nixos-26.05`, home-manager
`release-26.05`, sops-nix) and `tests/unstable` (both unstable), each with its
own lock and ftl as a relative input; `nix flake check ./tests/stable` or
`./tests/unstable` runs it, fully offline once the inputs are fetched. A canary
bumps one of them (`nix flake update` in that directory) and runs its check to
see whether the library still works with the channel's current head:

- `unit-loader`, `unit-static`, `unit-packages`, `unit-home`, `unit-nixos`,
  `unit-users`, `unit-deploy`: each `mk*` called directly on its folder of
  `tests/fixtures/layout`;
- `unit-smartcard`: reader registration, the udev filter, scdaemon, and the
  hand-over to nix-piv's agent (stubbed); `unit-agents`: the rendered
  AGENTS.md; `unit-fleet`: the ssh blocks, the fleet's caches, the Nix
  defaults and the repository as a git URL;
- `flake-isolated`: each family through `mkFlake` with all other folders
  disabled;
- `flake-full`: all families together (overlay and config in hosts and layers,
  homes in hosts, `static` everywhere, manifest, per-system checks,
  pass-through, renamed folders);
- `cli`: the fixture's `.sops.yaml` is what `fleetl secrets render` makes of
  its layout (the `fleet-sops` check); on stubs, `fleetl host exec` reaches
  each host with the deploy output's address and login, pinned to its
  `ssh.pub`, and `fleet generate` and `host generate` make a CA and a
  certificate signed by it, inputs first, into the right stores;
- `agents`: the fixture's and the template's `AGENTS.md` are current, and a
  stale one fails (the `fleet-agents` check);
- VM tests:
  - `modules`: a `mkFlake` host with every ftl module enabled;
  - `push`: an admin pushes an unsigned closure with nobody trusted. A plain
    push is refused, so is sudo without the forwarded agent, and
    `sudo nix-daemon` with it succeeds, without a terminal; `nix-copy-closure`
    and `nix copy` afterwards find nothing to add;
  - `smartcard`: two hosts with QEMU's emulated CCID reader. The one that
    registered it sees it through pcscd, the other does not. Also scdaemon,
    `/etc/AGENTS.md`, the ssh blocks and the Nix defaults;
  - `state-btrfs`, `state-zfs`: `fleet.state` on an empty disk, then a
    filesystem or pool;
  - `backup-btrfs`, `backup-zfs`: `fleet.backup` into a local repository:
    init only by hand, labels, tags and hosts of the snapshots, owners kept,
    the entry backed up rather than what is mounted at its path, no
    snapshot or scratch directory left, a vanished repository failing;
    restores of the latest and of an older backup swapped in with the
    current content kept aside, rollback and discard, an entry mounted
    inside another left alone, what needs the units, timers and a template
    unit's socket stopped and started again, units blocked while stopped,
    leftover snapshots replaced, a failing entry not failing the others;
  - `move`: `fleetl service move` from a btrfs host to a ZFS host through
    an admin machine (stubbed evaluation, real ssh and `fleet-state`):
    refusals, a failed move undone without touching what was in the way,
    then a move whose target, once switched to the moved configuration,
    runs the service on the received state (content, owners, xattrs, ZFS
    properties), a move `--via backup` restored on the target from the
    source's sftp repository with no credentials left behind and the top
    directories' owners and modes kept, and a source that lets go and drops
    its frozen copies after its deploy, not before;
  - `services`: `fleet.secrets` with sops-nix for real: a host decrypts its own
    store and a service's with its SSH host key, no age key installed;
  - `layers`: layer install, update, pins and rollback, plus the comin hook;
  - `pipeline`: fast-forward, layer pinning, broken builds, retention,
    daemon-signed cache, refusal of an unsigned branch tip, lane locking;
  - `cache`: signed substitution.
