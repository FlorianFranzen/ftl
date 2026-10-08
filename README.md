# ftl — flake template library

ftl turns a repository with a standard folder layout into flake outputs, and
adds an optional fleet-update pipeline on top. Every root folder is one output
family, handled by its own `mk*` function that only looks at that folder;
`ftl.lib.mkFlake` runs on the repository root and delegates to them. Each
`mk*` function can also be used on its own.

| Root folder | Contents | Function | Flake outputs |
|---|---|---|---|
| `pkgs/` | `<name>/package.nix` (nixpkgs by-name shape; patches, scripts and `test.nix` next to it); optional `overlay.nix` (overrides, kernel modules, anything else; may use any other subfolder); optional `config.nix` (nixpkgs config, e.g. the unfree allow-list) | `mkPackages` | `overlays.default`, `packages.<sys>` (the `<name>/package.nix` packages available on that system), `legacyPackages.<sys>` (the full package set, shared by everything else) |
| `nixos/` | `hosts/<name>/*.nix` (modules of a host; `host.nix` is metadata `{ system; importance; layers; }`, not a module); `modules/**.nix` (imported into every host); `profiles/**.nix` (opt-in via the `profiles` argument); `layers/<name>.nix` (layers, see below) | `mkNixos` | `nixosConfigurations`, `nixosModules`, `nixosProfiles`, `nixosLayers.<sys>.<name>`; checks `nixos-<host>`, `nixos-layer-<name>` |
| `home/` | `modules/**.nix` (shared into every configuration); `profiles/<dir>/*.nix` (building blocks); `variants/*.nix` | `mkHome` | `homeModules`, `homeProfiles`, `homeConfigurations.<name>`, `legacyPackages.<sys>.homeConfigurations.<name>`; checks `home-<name>` |
| `static/` | any files and folders (wallpapers, complete config dirs, …) | `mkStatic` | none; available as the module argument `static` |

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
    configurations as modules) and `static`.
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

- **Layers** (`nixos/layers/<name>.nix`, `{ kind; packages = pkgs: [ … ]; services; }`)
  are independently versioned Nix profiles under
  `/nix/var/nix/profiles/layers/<name>`, combined with the base system at
  runtime:
  - `kind = "apps"`: added via `environment.profiles`;
  - `kind = "services"`: unit files linked in by a systemd generator, so an
    update needs only `daemon-reload` and a restart.

  Hosts list their layers in `host.nix`. Each layer's revision comes from
  `ftl-layers.json`: `latest`, or the commit it last built at.
- **`ftl.builder`** (pipeline) bumps flake inputs per lane, builds everything in
  `ftlManifest` with `nix-fast-build`, signs and pushes results into a
  `file://` cache, and fast-forwards the deployed branch with a signed lock-bump
  commit once every required host builds. A red layer is pinned in
  `ftl-layers.json`, never blocking.
- **`ftl.cache`** serves that cache and the status JSON.
- **`ftl.layers`** installs the layers on hosts, verifies the target commit, and
  provides `ftl-layers update | list | rollback <name>`.
- **`ftl.comin`** connects [comin](https://github.com/nlewo/comin), which deploys
  the base system. Its post-deploy hook updates the layers; on lanzaboote hosts
  it also mirrors comin's generation into the `system` profile.
- **`ftl.client`** provides substituters, gc defaults and `ftl-status`.

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
  - `pipeline`: fast-forward, layer pinning, broken builds, retention;
  - `cache`: signed substitution.
