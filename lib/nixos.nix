# mkNixos: nixos/ folder -> NixOS configurations, modules, profiles, layers.
#
#   nixos/hosts/<name>/*.nix  modules of host <name>; host.nix is metadata
#                             { system?; importance?; layers?; ... }, not a
#                             module. Any further attributes are free-form host
#                             data, visible to every host via `fleet.hosts`.
#                             every <name>.pub next to it is a public key of the
#                             host (`keys.<name>`: ssh.pub, initrd.pub, wireguard.pub,
#                             ...), sops.age an age recipient used instead of the
#                             SSH key (`keys.age`), secrets.yaml its secret store
#                             and identity.yaml its private host keys (admins only).
#   nixos/generators/<name>.nix
#                             how to make a set of files for a host ({ pkgs }:
#                             { files; script; runtimeInputs; }): public ones
#                             land next to host.nix, secret ones in its stores.
#                             host.nix lists the generators a host uses
#                             (`generators`, host-keys by default); `fleetl host
#                             generate` runs them.
#   nixos/modules/**.nix      imported into every host (nixosModules)
#   nixos/profiles/**.nix     opt-in modules, available as `profiles` argument
#   nixos/layers/<name>.nix   layer definitions { kind; packages; units; }
#   nixos/services/<name>/*.nix
#                             modules of a service, imported on the hosts its
#                             service.nix names: { hosts; } or { roles.<r>.hosts; },
#                             plus layers the service brings along and free-form
#                             data. home.nix is left to the home side.
#
# Hosts, layers and services can also be given (or overridden) explicitly. Every host
# gets ftl's own NixOS modules (all disabled by default) and the meta module.
#
# Every host also receives the `fleet` module argument: `fleet.hosts.<name> =
# { name; system; importance; layers; } // <free-form data>` is all hosts'
# metadata, `fleet.self` the host's own entry. It is built from host.nix alone,
# without evaluating any configuration, so modules can use it anywhere (even in
# imports) without infinite recursion, e.g. to derive mesh endpoints, scrape
# targets or DNS records from the host list. `fleet.services.<name>` is every
# service's metadata the same way, `fleet.users.<name>` every user with the
# hosts it has an account on resolved.
#
# The parts live in nixos/: hosts, services, users, sops (the stores and their
# recipients), generators and layers. Each is a function of the shared context
# (the arguments below plus every other part's results), so the data flows
# between them without a fixed order: users need the services' hosts, hosts
# need their services and users, the stores need all three. This file only
# assembles the configurations, the checks and the manifest from them.
{
  src ? null,
  # the repository root, for the paths in `sops` (defaults to the parent of src)
  root ? null,
  nixpkgs,
  name ? "nixos",
  repo ? null,
  # hosts.<name> = { system?; importance?; modules?; layers?; } (merged over
  # discovered hosts; modules are appended)
  hosts ? { },
  # layers.<name> = { kind?; packages?; units?; } (merged over discovered)
  layers ? { },
  # services.<name> = { hosts?; roles?; layers?; modules?; ... } (merged over discovered)
  services ? { },
  # users.<name> = { admin?; hosts?; services?; home?; uid?; groups?; keys?; ... } (see mkUsers);
  # home is a configuration name, or { default?; <host>?; } for one per host
  users ? { },
  # system -> package set used to build layers
  pkgsFor ? system: import nixpkgs { inherit system; },
  specialArgs ? { },
  sharedModules ? [ ],
  # merged under nixos/profiles (local profiles win)
  extraProfiles ? { },
  # static files tree (see mkStatic), passed as `static`
  static ? { },
  # home configurations as modules, passed as `homes`
  homes ? { },
  # home configuration name -> NixOS modules it needs on the host (see mkHome)
  homeCompanions ? { },
}:
let
  lib = nixpkgs.lib;
  loader = import ./loader.nix;
  kinds = import ./kinds.nix lib;

  root' =
    if root != null then
      root
    else if src != null then
      dirOf src
    else
      null;
  dir = sub: if src == null then null else src + "/${sub}";
  exists = sub: src != null && builtins.pathExists (dir sub);

  # The arguments and helpers every part sees, plus every part's results.
  ctx = lib.fix (
    ctx:
    {
      inherit
        lib
        loader
        kinds
        root'
        dir
        exists
        hosts
        layers
        services
        users
        pkgsFor
        homes
        homeCompanions
        ;
    }
    // import ./nixos/hosts.nix ctx
    // import ./nixos/services.nix ctx
    // import ./nixos/users.nix ctx
    // import ./nixos/sops.nix ctx
    // import ./nixos/generators.nix ctx
    // import ./nixos/layers.nix ctx
  );

  inherit (ctx)
    hosts'
    services'
    users'
    peers
    serviceInfo
    userInfo
    servicesOf
    serviceModules
    nixosServices
    homeModule
    sops
    generators
    generatorPrograms
    layerKind
    layerSystems
    nixosLayers
    ;

  nixosModules = loader.loadTreeIfExists { dir = dir "modules"; };
  nixosProfiles = loader.loadTreeIfExists { dir = dir "profiles"; };
  profiles = lib.recursiveUpdate extraProfiles nixosProfiles;

  # --- configurations --------------------------------------------------------
  metaModule =
    hostName: host:
    { lib, ... }:
    {
      imports = [ ../modules/meta.nix ];
      config = {
        fleet.meta = {
          environment = name;
          inherit repo;
          host = hostName;
          attr = hostName;
          inherit (host)
            importance
            system
            layers
            services
            users
            ;
        };
        fleet.layers.installed = lib.genAttrs host.layers (l: {
          kind = layerKind l;
        });
        fleet.layers.repo = lib.mkIf (repo != null) (lib.mkDefault repo);
        fleet.secrets = lib.mkIf (host.dir != null) {
          file = lib.mkIf (builtins.pathExists (host.dir + "/secrets.yaml")) (host.dir + "/secrets.yaml");
          ageKeyFile = lib.mkIf (peers.${hostName} ? keys.age) "/var/lib/sops-nix/key.txt";
        };
        networking.hostName = lib.mkDefault hostName;
        nixpkgs.hostPlatform = lib.mkDefault host.system;
      };
    };

  ftlModules = import ../modules/all.nix;

  # The fleet as every host sees it; `self` is added per host below.
  fleet = {
    hosts = peers;
    services = serviceInfo;
    users = userInfo;
  };

  specialArgs' = specialArgs // {
    inherit
      profiles
      homes
      static
      ;
  };

  # The exact nixosSystem arguments of every host (also attached to each
  # configuration as `fleetArgs`, e.g. for building VM tests from a host).
  systemArgs = builtins.mapAttrs (hostName: host: {
    modules =
      sharedModules
      ++ ftlModules
      ++ loader.collectPaths nixosModules
      ++ lib.concatLists (lib.mapAttrsToList (serviceModules hostName) (servicesOf hostName))
      ++ host.modules
      ++ homeModule hostName
      ++ [ (metaModule hostName host) ];
    specialArgs = specialArgs' // {
      fleet = fleet // {
        self = peers.${hostName};
      };
    };
  }) hosts';

  nixosConfigurations = builtins.mapAttrs (
    _: a: nixpkgs.lib.nixosSystem a // { fleetArgs = a; }
  ) systemArgs;

  # --- checks and manifest ---------------------------------------------------
  manifestEntries =
    lib.mapAttrsToList (hostName: host: {
      checkName = "nixos-${hostName}";
      kind = "nixos";
      host = hostName;
      layer = null;
      inherit (host) system importance;
      configAttr = "nixosConfigurations.${hostName}";
    }) hosts'
    ++ lib.flatten (
      lib.mapAttrsToList (
        layerName: systems:
        map (system: {
          checkName = "nixos-layer-${layerName}";
          kind = "layer";
          host = null;
          layer = layerName;
          inherit system;
          importance = "optional";
          configAttr = "nixosLayers.${system}.${layerName}";
        }) systems
      ) layerSystems
    );

  activeEntries = lib.filter (e: e.importance != "ignored") manifestEntries;

  checks = lib.genAttrs (lib.unique (map (e: e.system) activeEntries)) (
    system:
    builtins.listToAttrs (
      map (e: {
        name = e.checkName;
        value =
          if e.kind == "nixos" then
            nixosConfigurations.${e.host}.config.system.build.toplevel
          else
            nixosLayers.${e.system}.${e.layer};
      }) (lib.filter (e: e.system == system) activeEntries)
    )
  );
in
# Validate every host and service spec eagerly (cheap; no NixOS evaluation involved).
assert builtins.all builtins.isAttrs (builtins.attrValues hosts');
assert builtins.all builtins.isAttrs (builtins.attrValues services');
assert builtins.all builtins.isAttrs (builtins.attrValues users');
{
  inherit
    nixosConfigurations
    nixosModules
    nixosProfiles
    nixosLayers
    nixosServices
    checks
    manifestEntries
    fleet
    sops
    generators
    generatorPrograms
    ;
  hosts = hosts';
  services = serviceInfo;
  users = userInfo;
}
