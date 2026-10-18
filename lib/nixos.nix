# mkNixos: nixos/ folder -> NixOS configurations, modules, profiles, layers.
#
#   nixos/hosts/<name>/*.nix  modules of host <name>; host.nix is metadata
#                             { system?; importance?; layers?; ... }, not a
#                             module. Any further attributes are free-form host
#                             data, visible to every host via `peers`.
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
# targets or DNS records from the host list. `peers` (= `fleet.hosts`) is the
# argument's former name. `fleet.services.<name>` is every service's metadata
# the same way.
#
# A service's modules get the `service` argument: its metadata, `role` (the
# roles this host has in it) and `dir` (its folder), so a module can say
# `service.port` or `service.dir + "/secrets.yaml"` without knowing where it is.
{
  src ? null,
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
}:
let
  lib = nixpkgs.lib;
  loader = import ./loader.nix;
  kinds = import ./kinds.nix lib;

  dir = sub: if src == null then null else src + "/${sub}";
  exists = sub: src != null && builtins.pathExists (dir sub);

  nixosModules = loader.loadTreeIfExists { dir = dir "modules"; };
  nixosProfiles = loader.loadTreeIfExists { dir = dir "profiles"; };
  profiles = lib.recursiveUpdate extraProfiles nixosProfiles;

  # --- hosts -----------------------------------------------------------------
  discoveredHosts =
    if !exists "hosts" then
      { }
    else
      lib.mapAttrs (
        hostName: _:
        let
          hostDir = dir "hosts/${hostName}";
          meta = if builtins.pathExists (hostDir + "/host.nix") then import (hostDir + "/host.nix") else { };
        in
        meta
        // {
          modules = loader.collectPaths (
            loader.loadTree {
              dir = hostDir;
              exclude = [ "host.nix" ];
            }
          );
        }
      ) (lib.filterAttrs (_: t: t == "directory") (builtins.readDir (dir "hosts")));

  hostSpecs = lib.zipAttrsWith (
    _: specs:
    let
      a = builtins.head specs;
      b = if builtins.length specs > 1 then builtins.elemAt specs 1 else { };
    in
    a // b // { modules = (a.modules or [ ]) ++ (b.modules or [ ]); }
  ) [
    discoveredHosts
    hosts
  ];

  # --- services --------------------------------------------------------------
  discoveredServices =
    if !exists "services" then
      { }
    else
      lib.mapAttrs (
        serviceName: _:
        let
          serviceDir = dir "services/${serviceName}";
          meta =
            if builtins.pathExists (serviceDir + "/service.nix") then
              import (serviceDir + "/service.nix")
            else
              { };
        in
        meta
        // {
          dir = serviceDir;
          modules = loader.collectPaths (
            loader.loadTree {
              dir = serviceDir;
              exclude = [
                "service.nix"
                "home.nix"
              ];
            }
          );
        }
      ) (lib.filterAttrs (_: t: t == "directory") (builtins.readDir (dir "services")));

  serviceSpecs = lib.zipAttrsWith (
    _: specs:
    let
      a = builtins.head specs;
      b = if builtins.length specs > 1 then builtins.elemAt specs 1 else { };
    in
    a // b // { modules = (a.modules or [ ]) ++ (b.modules or [ ]); }
  ) [
    discoveredServices
    services
  ];

  # Attributes of a service spec that ftl interprets; everything else is data.
  reservedServiceAttrs = [
    "name"
    "hosts"
    "roles"
    "layers"
    "modules"
    "dir"
  ];

  normalizeService =
    serviceName: spec:
    let
      # `hosts` is short for `roles.default.hosts`
      roles =
        lib.mapAttrs (_: r: { hosts = r.hosts or [ ]; }) (spec.roles or { })
        // lib.optionalAttrs (spec ? hosts) { default.hosts = spec.hosts; };
      service = {
        inherit roles;
        hosts = lib.unique (lib.concatMap (r: r.hosts) (builtins.attrValues roles));
        layers = spec.layers or [ ];
        modules = spec.modules or [ ];
        dir = spec.dir or null;
        data = builtins.removeAttrs spec reservedServiceAttrs;
      };
      unknownHosts = lib.filter (h: !(hostSpecs ? ${h})) service.hosts;
      unknownLayers = lib.filter (l: !(layers' ? ${l})) service.layers;
    in
    assert lib.assertMsg (!(spec ? name))
      "ftl: service '${serviceName}' sets reserved attribute 'name' (the directory name is the service name)";
    assert lib.assertMsg (unknownHosts == [ ])
      "ftl: service '${serviceName}' names undefined hosts: ${toString unknownHosts}";
    assert lib.assertMsg (unknownLayers == [ ])
      "ftl: service '${serviceName}' uses undefined layers: ${toString unknownLayers}";
    service;

  services' = builtins.mapAttrs normalizeService serviceSpecs;

  # The services a host runs, and its roles in one of them.
  servicesOf = hostName: lib.filterAttrs (_: s: builtins.elem hostName s.hosts) services';
  rolesOf =
    hostName: service: builtins.attrNames (lib.filterAttrs (_: r: builtins.elem hostName r.hosts) service.roles);

  # Every service's metadata, as seen by every host (`fleet.services`).
  serviceInfo = builtins.mapAttrs (
    serviceName: service:
    service.data
    // {
      name = serviceName;
      inherit (service) hosts roles layers;
    }
  ) services';

  # A service's modules with their `service` argument. On a host the roles are
  # known; the exported module (nixosServices) looks them up by the host name
  # of whatever configuration imports it.
  serviceModules =
    hostName: serviceName: service:
    let
      arg =
        args:
        serviceInfo.${serviceName}
        // {
          inherit (service) dir;
          role = rolesOf (if hostName != null then hostName else args.config.fleet.meta.host) service;
        };
      withArg =
        path:
        let
          m = import path;
        in
        {
          _file = toString path;
          key = toString path;
          imports = [
            (
              if builtins.isFunction m then
                lib.setFunctionArgs (args: m (args // { service = arg args; })) (
                  builtins.removeAttrs (lib.functionArgs m) [ "service" ]
                )
              else
                m
            )
          ];
        };
    in
    map withArg service.modules;

  nixosServices = builtins.mapAttrs (serviceName: service: {
    imports = serviceModules null serviceName service;
  }) services';

  # --- layers ----------------------------------------------------------------
  discoveredLayers = builtins.mapAttrs (_: import) (loader.loadTreeIfExists { dir = dir "layers"; });
  layers' = discoveredLayers // layers;

  importances = [
    "required"
    "optional"
    "ignored"
  ];

  # Attributes of a host spec that ftl interprets; everything else is data.
  reservedHostAttrs = [
    "name"
    "system"
    "importance"
    "modules"
    "layers"
    "services"
  ];

  normalizeHost =
    hostName: spec:
    let
      ownServices = servicesOf hostName;
      host = {
        system = spec.system or "x86_64-linux";
        importance = spec.importance or "required";
        modules = spec.modules or [ ];
        # its own layers, and those of its services
        layers = lib.unique (
          (spec.layers or [ ]) ++ lib.concatMap (s: s.layers) (builtins.attrValues ownServices)
        );
        services = builtins.attrNames ownServices;
        data = builtins.removeAttrs spec reservedHostAttrs;
      };
      unknownLayers = lib.filter (l: !(layers' ? ${l})) (spec.layers or [ ]);
    in
    assert lib.assertMsg (!(spec ? name))
      "ftl: host '${hostName}' sets reserved attribute 'name' (the directory name is the host name)";
    assert lib.assertMsg (builtins.elem host.importance importances)
      "ftl: host '${hostName}' has invalid importance '${host.importance}'";
    assert lib.assertMsg (unknownLayers == [ ])
      "ftl: host '${hostName}' uses undefined layers: ${toString unknownLayers}";
    assert lib.assertMsg (!lib.hasPrefix "layer-" hostName)
      "ftl: host name '${hostName}' collides with layer check names (nixos-layer-*)";
    host;

  hosts' = builtins.mapAttrs normalizeHost hostSpecs;

  # Every host's metadata, as seen by every host, itself included (`peers` argument).
  peers = builtins.mapAttrs (
    hostName: host:
    host.data
    // {
      name = hostName;
      inherit (host)
        system
        importance
        layers
        services
        ;
    }
  ) hosts';

  # Systems each layer is needed for (only where a non-ignored host uses it).
  layerSystems = builtins.mapAttrs (
    layerName: _:
    lib.unique (
      lib.mapAttrsToList (_: h: h.system) (
        lib.filterAttrs (_: h: h.importance != "ignored" && builtins.elem layerName h.layers) hosts'
      )
    )
  ) layers';

  layerKind =
    layerName: kinds.normalize "layer '${layerName}'" (layers'.${layerName}.kind or "packages");

  nixosLayers = lib.genAttrs (lib.unique (lib.flatten (builtins.attrValues layerSystems))) (
    system:
    builtins.mapAttrs
      (
        layerName: def:
        import ./layer.nix {
          pkgs = pkgsFor system;
          name = layerName;
          kind = layerKind layerName;
          packages = def.packages or [ ];
          units = def.units or { };
          services = def.services or null;
        }
      )
      (lib.filterAttrs (layerName: _: builtins.elem system layerSystems.${layerName}) layers')
  );

  # --- configurations --------------------------------------------------------
  metaModule =
    hostName: host:
    { lib, ... }:
    {
      imports = [
        ../modules/meta.nix
        ../modules/layers.nix
        ../modules/comin.nix
        ../modules/compat.nix
      ];
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
            ;
        };
        fleet.layers.installed = lib.genAttrs host.layers (l: {
          kind = layerKind l;
        });
        networking.hostName = lib.mkDefault hostName;
        nixpkgs.hostPlatform = lib.mkDefault host.system;
      };
    };

  ftlModules = [
    ../modules/builder.nix
    ../modules/cache.nix
    ../modules/client.nix
    ../modules/layers.nix
    ../modules/comin.nix
  ];

  # The fleet as every host sees it; `self` is added per host below.
  fleet = {
    hosts = peers;
    services = serviceInfo;
  };

  specialArgs' = specialArgs // {
    inherit
      profiles
      homes
      static
      peers
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
      ++ [ (metaModule hostName host) ];
    specialArgs = specialArgs' // {
      fleet = fleet // {
        self = peers.${hostName};
      };
    };
  }) hosts';

  nixosConfigurations = builtins.mapAttrs (
    _: a:
    nixpkgs.lib.nixosSystem a
    // {
      fleetArgs = a;
      ftlArgs = lib.warn "ftl: `ftlArgs` is called `fleetArgs` now" a;
    }
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
{
  inherit
    nixosConfigurations
    nixosModules
    nixosProfiles
    nixosLayers
    nixosServices
    checks
    manifestEntries
    peers
    fleet
    ;
  hosts = hosts';
  services = serviceInfo;
}
