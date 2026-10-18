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
# targets or DNS records from the host list. `peers` (= `fleet.hosts`) is the
# argument's former name. `fleet.services.<name>` is every service's metadata
# the same way.
#
# `fleet.users.<name>` is every user (see mkUsers) with the hosts it has an
# account on resolved: an admin is on every host, anyone else on the hosts
# listed and on the hosts of the services listed. The access module turns
# that into accounts.
#
# A service's modules get the `service` argument: its metadata, `role` (the
# roles this host has in it), `dir` (its folder) and `sopsFile` (its secret
# store, <dir>/secrets.yaml), so a module can say `service.port` or
# `sops.secrets.x.sopsFile = service.sopsFile` without knowing where it is.
#
# Every store's recipients follow from the layout (`sops` below, the
# `fleet.sops` output): a host's store is for the host and the admins, its
# identity for the admins, a service's store for its hosts, the admins and the
# users listing it, a user's store for that user.
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

  root' = if root != null then root else if src != null then dirOf src else null;
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
          # the first line of a key file that is not a comment
          key =
            file: attr:
            let
              lines = lib.filter (l: l != "" && !lib.hasPrefix "#" l) (
                map lib.trim (lib.splitString "\n" (builtins.readFile (hostDir + "/${file}")))
              );
            in
            lib.optionalAttrs (builtins.pathExists (hostDir + "/${file}") && lines != [ ]) {
              ${attr} = builtins.head lines;
            };
          pubFiles = lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".pub" n) (builtins.readDir hostDir);
          keys =
            (meta.keys or { })
            // lib.concatMapAttrs (n: _: key n (lib.removeSuffix ".pub" n)) pubFiles
            // key "sops.age" "age";
        in
        meta
        // lib.optionalAttrs (keys != { }) { inherit keys; }
        // {
          dir = hostDir;
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

  # --- generators --------------------------------------------------------------
  # ftl's own (the host keys every host needs, a dedicated age key) under the
  # repository's nixos/generators.
  generatorFiles = {
    host-keys = ./generators/host-keys.nix;
    age-key = ./generators/age-key.nix;
  }
  // loader.loadTreeIfExists { dir = dir "generators"; };

  # What a generator makes, without a package set (`fleet.generators`).
  generators = builtins.mapAttrs (
    name: file:
    let
      g = import file { pkgs = throw "ftl: generator '${name}' may use pkgs only in runtimeInputs"; };
    in
    {
      inherit (g) files;
      description = g.description or name;
    }
  ) generatorFiles;

  # generate-<name> <dir>: the generator as a program, writing its files into <dir>.
  generatorPrograms =
    system:
    let
      pkgs = pkgsFor system;
    in
    builtins.mapAttrs (
      name: file:
      let
        g = import file { inherit pkgs; };
      in
      pkgs.writeShellApplication {
        name = "generate-${name}";
        runtimeInputs = g.runtimeInputs or [ ];
        text = ''
          out="''${1:?usage: generate-${name} <dir>}"
          HOST="''${HOST:-host}"
          export HOST out
          mkdir -p "$out"
          ${g.script}
        '';
      }
    ) generatorFiles;

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
          sopsFile = if service.dir != null then service.dir + "/secrets.yaml" else null;
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

  # --- users -----------------------------------------------------------------
  reservedUserAttrs = [
    "name"
    "admin"
    "hosts"
    "services"
    "home"
    "uid"
    "groups"
    "keys"
    "dir"
  ];

  normalizeUser =
    userName: spec:
    let
      admin = spec.admin or false;
      user = {
        inherit admin;
        services = spec.services or [ ];
        # an admin is everywhere unless told otherwise; everyone is where their services are
        hosts = lib.unique (
          (if spec ? hosts then spec.hosts else lib.optionals admin (builtins.attrNames hostSpecs))
          ++ lib.concatMap (s: services'.${s}.hosts) (spec.services or [ ])
        );
        home = spec.home or null;
        uid = spec.uid or null;
        groups = spec.groups or [ ];
        keys = {
          ssh = [ ];
          pgp = [ ];
          age = [ ];
        }
        // (spec.keys or { });
        dir = spec.dir or null;
        data = builtins.removeAttrs spec reservedUserAttrs;
      };
      unknownHosts = lib.filter (h: !(hostSpecs ? ${h})) (spec.hosts or [ ]);
      unknownServices = lib.filter (s: !(serviceSpecs ? ${s})) user.services;
      homeNames =
        if user.home == null then
          [ ]
        else if builtins.isString user.home then
          [ user.home ]
        else
          lib.filter (h: h != null) (builtins.attrValues user.home);
      unknownHomes = lib.filter (h: !(homes ? ${h})) homeNames;
    in
    assert lib.assertMsg (!(spec ? name))
      "ftl: user '${userName}' sets reserved attribute 'name' (the directory name is the user name)";
    assert lib.assertMsg (unknownHosts == [ ])
      "ftl: user '${userName}' names undefined hosts: ${toString unknownHosts}";
    assert lib.assertMsg (unknownServices == [ ])
      "ftl: user '${userName}' names undefined services: ${toString unknownServices}";
    assert lib.assertMsg (unknownHomes == [ ])
      "ftl: user '${userName}' wants home configurations that do not exist: ${toString unknownHomes}";
    lib.warnIf (user.hosts != [ ] && user.keys.ssh == [ ])
      "ftl: user '${userName}' has an account on ${toString (builtins.length user.hosts)} host(s) but no SSH key (ssh.pub)"
      user;

  users' = builtins.mapAttrs normalizeUser users;

  usersOf = hostName: lib.filterAttrs (_: u: builtins.elem hostName u.hosts) users';

  # The home configuration a user gets on a host: one name for everywhere, or
  # the host's entry (falling back to `default`) of a per-host attrset.
  # (`<host> = null` in the attrset means none on that host.)
  homeOf =
    hostName: user:
    if user.home == null || builtins.isString user.home then
      user.home
    else if user.home ? ${hostName} then
      user.home.${hostName}
    else
      user.home.default or null;

  # Every user, as seen by every host (`fleet.users`).
  userInfo = builtins.mapAttrs (
    userName: user:
    user.data
    // {
      name = userName;
      inherit (user)
        admin
        hosts
        services
        home
        uid
        groups
        keys
        ;
    }
  ) users';

  # The home configurations of a host's users, and the NixOS side those
  # configurations' profiles need (their nixos.nix companions).
  homeModule =
    hostName:
    let
      withHome = lib.filterAttrs (_: u: homeOf hostName u != null) (usersOf hostName);
      names = lib.unique (lib.mapAttrsToList (_: u: homeOf hostName u) withHome);
    in
    lib.optional (withHome != { }) {
      home-manager.users = lib.mapAttrs (_: u: homes.${homeOf hostName u}) withHome;
    }
    ++ lib.unique (lib.concatMap (n: homeCompanions.${n} or [ ]) names);

  # --- secret stores ---------------------------------------------------------
  # Who can read which store: recipients are sops keys (pgp fingerprints, age
  # recipients) and SSH host keys still to be converted with ssh-to-age.
  recipientsOf =
    {
      hostNames ? [ ],
      userNames ? [ ],
    }:
    let
      hostKeys = map (h: peers.${h}.keys or { }) hostNames;
      userKeys = map (u: users'.${u}.keys) userNames;
      ofHosts = f: lib.concatMap f hostKeys;
    in
    {
      pgp = lib.unique (lib.concatMap (k: k.pgp) userKeys);
      age = lib.unique (lib.concatMap (k: k.age) userKeys ++ ofHosts (k: lib.optional (k ? age) k.age));
      ssh = lib.unique (ofHosts (k: lib.optional (k ? ssh && !(k ? age)) k.ssh));
    };

  admins = builtins.attrNames (lib.filterAttrs (_: u: u.admin) users');

  store =
    kind: owner: dir: file: recipients:
    lib.optional (dir != null && recipients != { pgp = [ ]; age = [ ]; ssh = [ ]; }) {
      inherit kind owner recipients;
      path = lib.removePrefix (toString root' + "/") (toString dir) + "/${file}";
    };

  stores =
    lib.concatLists (
      lib.mapAttrsToList (
        hostName: host:
        store "host" hostName host.dir "secrets.yaml" (recipientsOf {
          hostNames = [ hostName ];
          userNames = admins;
        })
        ++ store "identity" hostName host.dir "identity.yaml" (recipientsOf { userNames = admins; })
      ) hosts'
    )
    ++ lib.concatLists (
      lib.mapAttrsToList (
        serviceName: service:
        store "service" serviceName service.dir "secrets.yaml" (recipientsOf {
          hostNames = service.hosts;
          userNames = lib.unique (
            admins ++ builtins.attrNames (lib.filterAttrs (_: u: builtins.elem serviceName u.services) users')
          );
        })
      ) services'
    )
    ++ lib.concatLists (
      lib.mapAttrsToList (
        userName: user: store "user" userName user.dir "secrets.yaml" (recipientsOf { userNames = [ userName ]; })
      ) users'
    );

  sops = {
    stores = lib.sort (a: b: a.path < b.path) stores;
  };

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
    "users"
    "dir"
    "generators"
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
        users = builtins.attrNames (usersOf hostName);
        generators = spec.generators or [ "host-keys" ];
        dir = spec.dir or null;
        data = builtins.removeAttrs spec reservedHostAttrs;
      };
      unknownLayers = lib.filter (l: !(layers' ? ${l})) (spec.layers or [ ]);
      unknownGenerators = lib.filter (g: !(generatorFiles ? ${g})) host.generators;
    in
    assert lib.assertMsg (!(spec ? name))
      "ftl: host '${hostName}' sets reserved attribute 'name' (the directory name is the host name)";
    assert lib.assertMsg (builtins.elem host.importance importances)
      "ftl: host '${hostName}' has invalid importance '${host.importance}'";
    assert lib.assertMsg (unknownLayers == [ ])
      "ftl: host '${hostName}' uses undefined layers: ${toString unknownLayers}";
    assert lib.assertMsg (!lib.hasPrefix "layer-" hostName)
      "ftl: host name '${hostName}' collides with layer check names (nixos-layer-*)";
    assert lib.assertMsg (unknownGenerators == [ ])
      "ftl: host '${hostName}' uses undefined generators: ${toString unknownGenerators}";
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
        users
        generators
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
            users
            ;
        };
        fleet.layers.installed = lib.genAttrs host.layers (l: {
          kind = layerKind l;
        });
        fleet.secrets = lib.mkIf (host.dir != null) {
          file = lib.mkIf (builtins.pathExists (host.dir + "/secrets.yaml")) (host.dir + "/secrets.yaml");
          ageKeyFile = lib.mkIf (peers.${hostName} ? keys.age) "/var/lib/sops-nix/key.txt";
        };
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
    ../modules/state.nix
    ../modules/access.nix
    ../modules/secrets.nix
  ];

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
      ++ homeModule hostName
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
    peers
    fleet
    sops
    generators
    generatorPrograms
    ;
  hosts = hosts';
  services = serviceInfo;
  users = userInfo;
}
