# mkFlake: repository root -> flake outputs.
#
# Every root folder is one output family, handled by its own mk* function:
#
#   pkgs/    mkPackages  overlays.default, packages, legacyPackages
#   nixos/   mkNixos     nixosConfigurations, nixosModules, nixosProfiles, nixosLayers,
#                        nixosServices, fleet.hosts, fleet.services
#   home/    mkHome      homeModules, homeProfiles, homeConfigurations
#   static/  mkStatic    the `static` module argument (no outputs)
#   users/   mkUsers     fleet.users, accounts on the hosts (through mkNixos)
#
# plus checks for all of them and `fleet.manifest`, consumed by the ftl
# pipeline. Everything the library itself exports is below `fleet`; the former
# `ftlPeers` and `ftlManifest` outputs remain as aliases with a warning.
# Missing folders are skipped; folder names can be changed with
# `layout.<family> = "dir"` (or null to disable). Unrecognized arguments are
# deep-merged into the outputs.
args@{
  src,
  inputs,
  name ? "flake",
  repo ? null,
  systems ? [
    "x86_64-linux"
    "aarch64-linux"
  ],
  layout ? { },
  # overlays applied before the local pkgs/ overlay
  overlays ? [ ],
  # nixpkgs config; defaults to pkgs/config.nix
  config ? null,
  # mkNixos options: specialArgs, sharedModules, extraProfiles, exportInputs,
  # hosts, layers, services
  nixos ? { },
  # mkHome options: bases, variants, systems, sharedModules, extraSpecialArgs,
  # username
  home ? { },
  # user specs merged over users/ (see mkUsers)
  users ? { },
  # sops: extraRules, creation rules appended to the generated .sops.yaml
  sops ? { },
  ...
}:
let
  nixpkgs = inputs.nixpkgs;
  lib = nixpkgs.lib;
  homeManager = inputs.home-manager or null;

  knownArgs = [
    "src"
    "inputs"
    "name"
    "repo"
    "systems"
    "layout"
    "overlays"
    "config"
    "nixos"
    "home"
    "users"
    "sops"
  ];
  passthru = builtins.removeAttrs args knownArgs;

  dirs = {
    pkgs = "pkgs";
    nixos = "nixos";
    home = "home";
    static = "static";
    users = "users";
  }
  // layout;
  folder =
    family:
    let
      d = dirs.${family};
    in
    if d != null && builtins.pathExists (src + "/${d}") then src + "/${d}" else null;

  # --- pkgs/ -----------------------------------------------------------------
  packages = import ./packages.nix {
    src = folder "pkgs";
    inherit
      nixpkgs
      systems
      overlays
      config
      ;
  };

  # --- static/ ---------------------------------------------------------------
  static = if folder "static" != null then import ./static.nix { src = folder "static"; } else { };

  # --- home/ -----------------------------------------------------------------
  homeSystems = home.systems or [ "x86_64-linux" ];
  homeOut =
    if folder "home" == null then
      null
    else
      import ./home.nix (
        {
          src = folder "home";
          inherit lib homeManager;
          inherit (packages) pkgsFor;
          systems = homeSystems;
        }
        // builtins.removeAttrs home [
          "systems"
          "extraSpecialArgs"
        ]
        // {
          extraSpecialArgs = {
            inherit static;
          }
          // (home.extraSpecialArgs or { });
        }
      );

  # --- users/ ----------------------------------------------------------------
  users' =
    (if folder "users" != null then (import ./users.nix { src = folder "users"; inherit lib; }).users else { })
    // users;

  # --- nixos/ ----------------------------------------------------------------
  integration = import ../modules/flake.nix {
    inherit inputs;
    inherit (packages) overlays;
    nixpkgsConfig = packages.config;
    exportInputs = nixos.exportInputs or [
      "self"
      "nixpkgs"
    ];
    homeManager = if homeOut != null then homeManager else null;
    homeSharedModules = if homeOut != null then homeOut.allSharedModules else [ ];
    homeExtraSpecialArgs = if homeOut != null then homeOut.extraSpecialArgs else { };
  };

  nixosOut =
    if folder "nixos" == null && (nixos.hosts or { }) == { } then
      null
    else
      import ./nixos.nix {
        src = folder "nixos";
        root = src;
        inherit
          nixpkgs
          name
          repo
          static
          ;
        inherit (packages) pkgsFor;
        hosts = nixos.hosts or { };
        layers = nixos.layers or { };
        services = nixos.services or { };
        users = users';
        specialArgs = nixos.specialArgs or { };
        extraProfiles = nixos.extraProfiles or { };
        homes = if homeOut != null then homeOut.modules else { };
        sharedModules =
          lib.optional (homeOut != null && homeManager != null) homeManager.nixosModules.home-manager
          ++ lib.optional (inputs ? sops-nix) inputs.sops-nix.nixosModules.sops
          ++ (nixos.sharedModules or [ ])
          ++ [ integration ];
      };

  # --- outputs -----------------------------------------------------------------
  hasPkgs = folder "pkgs" != null;
  homeConfigsFor = system: if homeOut != null then homeOut.configurations.${system} or { } else { };

  # Decided statically, so that accessing other outputs never evaluates nixpkgs.
  hasHomeConfigs = homeOut != null && homeManager != null;
  legacySystems =
    lib.optionals hasPkgs systems ++ lib.optionals hasHomeConfigs homeSystems;

  legacyPackages = lib.genAttrs (lib.unique legacySystems) (
    system:
    let
      withHomes = lib.optionalAttrs (hasHomeConfigs && builtins.elem system homeSystems) {
        homeConfigurations = homeConfigsFor system;
      };
    in
    if hasPkgs then packages.pkgsFor system // withHomes else withHomes
  );

  checks = lib.foldl' lib.recursiveUpdate { } [
    (if nixosOut != null then nixosOut.checks else { })
    (if homeOut != null then lib.filterAttrs (_: c: c != { }) homeOut.checks else { })
  ];

  manifest = import ./manifest.nix {
    inherit name repo;
    entries =
      (if nixosOut != null then nixosOut.manifestEntries else [ ])
      ++ (if homeOut != null then homeOut.manifestEntries else [ ]);
  };

  outputs = lib.foldl' lib.recursiveUpdate { } [
    (lib.optionalAttrs hasPkgs {
      overlays.default = packages.overlay;
      inherit (packages) packages;
    })
    (lib.optionalAttrs (legacySystems != [ ]) { inherit legacyPackages; })
    (lib.optionalAttrs (homeOut != null) (
      {
        inherit (homeOut) homeModules homeProfiles;
      }
      // lib.optionalAttrs hasHomeConfigs {
        homeConfigurations = homeConfigsFor (builtins.head homeSystems);
      }
    ))
    (lib.optionalAttrs (nixosOut != null) {
      inherit (nixosOut)
        nixosConfigurations
        nixosModules
        nixosProfiles
        nixosLayers
        nixosServices
        ;
      # metadata of all hosts and services (`fleet.hosts` and `fleet.services`
      # in every host)
      fleet.hosts = nixosOut.peers;
      fleet.services = nixosOut.services;
      fleet.users = nixosOut.users;
      # every secret store and its recipients, for `fleetl secrets sync`
      fleet.sops = nixosOut.sops // {
        extraRules = sops.extraRules or [ ];
      };
      ftlPeers = lib.warn "ftl: the `ftlPeers` output is `fleet.hosts` now" nixosOut.peers;
    })
    (lib.optionalAttrs (checks != { }) { inherit checks; })
    {
      fleet.manifest = manifest;
      ftlManifest = lib.warn "ftl: the `ftlManifest` output is `fleet.manifest` now" manifest;
    }
    passthru
  ];
in
outputs
