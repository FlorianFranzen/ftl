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
# plus checks for all of them, `fleet.manifest`, consumed by the ftl pipeline,
# and `fleet.agents`, the AGENTS.md of the repository (`fleetl agents sync`).
# Everything the library itself exports is below `fleet`.
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
  # smartcard readers every host accepts: { presence?; readers.<name> = { vendor;
  # product?; serial?; port?; description?; }; } (hosts add their own in host.nix)
  smartcard ? { },
  # AGENTS.md: extra, strings or files appended to the generated one
  agents ? { },
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
    "smartcard"
    "agents"
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
    (
      if folder "users" != null then
        (import ./users.nix {
          src = folder "users";
          inherit lib;
        }).users
      else
        { }
    )
    // users;

  # --- nixos/ ----------------------------------------------------------------
  integration = import ../modules/flake.nix {
    inherit inputs;
    inherit (packages) overlays;
    nixpkgsConfig = packages.config;
    exportInputs =
      nixos.exportInputs or [
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
        inherit smartcard;
        specialArgs = nixos.specialArgs or { };
        extraProfiles = nixos.extraProfiles or { };
        homes = if homeOut != null then homeOut.modules else { };
        homeCompanions = if homeOut != null then homeOut.companions else { };
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
  legacySystems = lib.optionals hasPkgs systems ++ lib.optionals hasHomeConfigs homeSystems;

  legacyPackages = lib.genAttrs (lib.unique legacySystems) (
    system:
    let
      withHomes = lib.optionalAttrs (hasHomeConfigs && builtins.elem system homeSystems) {
        homeConfigurations = homeConfigsFor system;
      };
    in
    if hasPkgs then packages.pkgsFor system // withHomes else withHomes
  );

  # --- fleetl and the .sops.yaml check -------------------------------------------
  hasFleet = nixosOut != null;
  sopsOut = if hasFleet then nixosOut.sops // { extraRules = sops.extraRules or [ ]; } else null;
  fleetlFor = system: (import ../modules/scripts.nix { pkgs = packages.pkgsFor system; }).fleetl;

  # .sops.yaml must be what `fleetl secrets sync` writes for the layout.
  sopsCheck =
    system:
    let
      pkgs = packages.pkgsFor system;
    in
    pkgs.runCommand "fleet-sops"
      {
        nativeBuildInputs = [
          (fleetlFor system)
          pkgs.diffutils
        ];
        stores = builtins.toJSON sopsOut;
        passAsFile = [ "stores" ];
        committed = src + "/.sops.yaml";
      }
      ''
        fleetl secrets render <"$storesPath" >generated.yaml
        if ! diff -u "$committed" generated.yaml; then
          echo ".sops.yaml is stale; run fleetl secrets sync" >&2
          exit 1
        fi
        touch "$out"
      '';

  # --- AGENTS.md ---------------------------------------------------------------
  # What an agent working on the repository or a host must know, rendered from
  # the metadata alone (no host is evaluated for it).
  agentsText = (import ./agents.nix { inherit lib; }).fleet {
    inherit name repo;
    inherit (nixosOut) caches;
    hosts = nixosOut.fleet.hosts;
    inherit (nixosOut) services users;
    extra = agents.extra or [ ];
  };

  # AGENTS.md must be what `fleetl agents sync` writes.
  agentsCheck =
    system:
    let
      pkgs = packages.pkgsFor system;
    in
    pkgs.runCommand "fleet-agents"
      {
        nativeBuildInputs = [ pkgs.diffutils ];
        generated = builtins.toFile "AGENTS.md" agentsText;
        committed = src + "/AGENTS.md";
      }
      ''
        if ! diff -u "$committed" "$generated"; then
          echo "AGENTS.md is stale; run fleetl agents sync" >&2
          exit 1
        fi
        touch "$out"
      '';

  # A generated file is checked once the repository has it: a fleet that never
  # ran the sync command is not red, a stale file is.
  hasFile = file: builtins.pathExists (src + "/${file}");
  fleetChecks = lib.filterAttrs (_: c: c != { }) (
    lib.optionalAttrs hasFleet (
      lib.genAttrs systems (
        system:
        lib.optionalAttrs (sopsOut.stores != [ ] && hasFile ".sops.yaml") {
          fleet-sops = sopsCheck system;
        }
        // lib.optionalAttrs (nixosOut.fleet.hosts != { } && hasFile "AGENTS.md") {
          fleet-agents = agentsCheck system;
        }
      )
    )
  );

  checks = lib.foldl' lib.recursiveUpdate { } [
    (if nixosOut != null then nixosOut.checks else { })
    (if homeOut != null then lib.filterAttrs (_: c: c != { }) homeOut.checks else { })
    fleetChecks
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
      fleet.hosts = nixosOut.fleet.hosts;
      fleet.services = nixosOut.services;
      fleet.users = nixosOut.users;
      # the fleet's own public files (nixos/<name>.pub)
      fleet.keys = nixosOut.keys;
      # the binary caches the hosts and services announce (fleet.client uses them)
      fleet.caches = nixosOut.caches;
      # the repository's AGENTS.md (`fleetl agents sync` writes it)
      fleet.agents = agentsText;
      # every secret store and its recipients, for `fleetl secrets sync`
      fleet.sops = sopsOut;
      # the generators as programs (fleetl host generate), and what they make
      fleet.generators = nixosOut.generators;
      # the admin's command line (nix run .#fleetl -- ...), ftl as alias
      packages = lib.genAttrs systems (
        system:
        {
          fleetl = fleetlFor system;
        }
        // lib.mapAttrs' (name: p: lib.nameValuePair "generate-${name}" p) (
          nixosOut.generatorPrograms system
        )
      );
      apps = lib.genAttrs systems (system: {
        fleetl = {
          type = "app";
          program = lib.getExe (fleetlFor system);
          meta.description = "The fleet from the admin's machine: secrets, hosts, users";
        };
      });
    })
    (lib.optionalAttrs (checks != { }) { inherit checks; })
    { fleet.manifest = manifest; }
    passthru
  ];
in
outputs
