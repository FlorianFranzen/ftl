# ftl — fleet template library

ftl turns a repository with a standard folder layout into the flake outputs of a
fleet of NixOS hosts, and adds an optional fleet-update pipeline on top. Every root folder is one output
family, handled by its own `mk*` function that only looks at that folder;
`ftl.lib.mkFlake` runs on the repository root and delegates to them. Each
`mk*` function can also be used on its own.

| Root folder | Contents | Function | Flake outputs |
|---|---|---|---|
| `pkgs/` | `<name>/package.nix` (nixpkgs by-name shape; patches, scripts and `test.nix` next to it); optional `overlay.nix` (overrides, kernel modules, anything else; may use any other subfolder); optional `config.nix` (nixpkgs config, e.g. the unfree allow-list) | `mkPackages` | `overlays.default`, `packages.<sys>` (the `<name>/package.nix` packages available on that system), `legacyPackages.<sys>` (the full package set, shared by everything else) |
| `nixos/` | `hosts/<name>/*.nix` (modules of a host; `host.nix` is metadata `{ system; importance; layers; … }`, not a module; further attributes are free-form host data); `modules/**.nix` (imported into every host); `profiles/**.nix` (opt-in via the `profiles` argument); `layers/<name>.nix` (layers, see below) | `mkNixos` | `nixosConfigurations`, `nixosModules`, `nixosProfiles`, `nixosLayers.<sys>.<name>`, `fleet.hosts`; checks `nixos-<host>`, `nixos-layer-<name>` |
| `home/` | `modules/**.nix` (shared into every configuration); `profiles/<dir>/*.nix` (building blocks); `variants/*.nix` | `mkHome` | `homeModules`, `homeProfiles`, `homeConfigurations.<name>`, `legacyPackages.<sys>.homeConfigurations.<name>`; checks `home-<name>` |
| `static/` | any files and folders (wallpapers, complete config dirs, …) | `mkStatic` | none; available as the module argument `static` |

Names: `ftl` is the library, its input and whatever lives on disk (`ftl-layers`,
`ftl-layers.json`, `/var/lib/ftl`); `fleet` is every Nix namespace it owns: the
`fleet.*` NixOS options, the `fleet` output and the `fleet` module argument. The
former `ftl.*` options and the `ftlPeers`/`ftlManifest` outputs still work, with a
warning, until the next release.

Missing folders are skipped. Folder names can be changed with
`layout.<family> = "dir"`, or a family disabled with `null`. Unrecognized
`mkFlake` arguments are deep-merged into the outputs.

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
  (`peers`, the argument's former name, is still passed as `fleet.hosts`.)

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
    repo = "github:me/infra";
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

## Fleet: layers, pipeline, cache

- **Layers** (`nixos/layers/<name>.nix`, `{ kind; packages = pkgs: [ … ]; units; }`)
  are independently versioned Nix profiles under
  `/nix/var/nix/profiles/layers/<name>`, combined with the base system at
  runtime:
  - `kind = "packages"`: added via `environment.profiles`;
  - `kind = "units"`: unit files linked in by a systemd generator, so an
    update needs only `daemon-reload` and a restart.

  (The kinds were `apps` and `services`, and `units` was `services`, before
  fleet services existed; the old names still work, with a warning.)

  Hosts list their layers in `host.nix`. Each layer's revision comes from
  `ftl-layers.json`: `latest`, or the commit it last built at.
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
- **`fleet.client`** provides substituters, gc defaults and `ftl-status`.

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

`nix flake check` runs, fully offline:

- `unit-loader`, `unit-static`, `unit-packages`, `unit-home`, `unit-nixos`:
  each `mk*` called directly on its folder of `tests/fixtures/layout`;
- `flake-isolated`: each family through `mkFlake` with all other folders
  disabled;
- `flake-full`: all families together (overlay and config in hosts and layers,
  homes in hosts, `static` everywhere, manifest, per-system checks,
  pass-through, renamed folders);
- VM tests:
  - `modules`: a `mkFlake` host with every ftl module enabled;
  - `layers`: layer install, update, pins and rollback, plus the comin hook;
  - `pipeline`: fast-forward, layer pinning, broken builds, retention,
    daemon-signed cache, refusal of an unsigned branch tip, lane locking;
  - `cache`: signed substitution.
