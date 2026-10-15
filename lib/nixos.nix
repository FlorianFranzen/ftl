# mkNixos: nixos/ folder -> NixOS configurations, modules, profiles, layers.
#
#   nixos/hosts/<name>/*.nix  modules of host <name>; host.nix is metadata
#                             { system?; importance?; layers?; ... }, not a
#                             module. Any further attributes are free-form host
#                             data, visible to every host via `peers`.
#   nixos/modules/**.nix      imported into every host (nixosModules)
#   nixos/profiles/**.nix     opt-in modules, available as `profiles` argument
#   nixos/layers/<name>.nix   layer definitions { kind; packages; services; }
#
# Hosts and layers can also be given (or overridden) explicitly. Every host
# gets ftl's own NixOS modules (all disabled by default) and the meta module.
#
# Every host also receives the `peers` module argument: all hosts' metadata,
# `peers.<name> = { name; system; importance; layers; } // <free-form data>`.
# It is built from host.nix alone, without evaluating any configuration, so
# modules can use it anywhere (even in imports) without infinite recursion,
# e.g. to derive mesh endpoints, scrape targets or DNS records from the host list.
{
  src ? null,
  nixpkgs,
  name ? "nixos",
  repo ? null,
  # hosts.<name> = { system?; importance?; modules?; layers?; } (merged over
  # discovered hosts; modules are appended)
  hosts ? { },
  # layers.<name> = { kind?; packages?; services?; } (merged over discovered)
  layers ? { },
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
  ];

  normalizeHost =
    hostName: spec:
    let
      host = {
        system = spec.system or "x86_64-linux";
        importance = spec.importance or "required";
        modules = spec.modules or [ ];
        layers = spec.layers or [ ];
        data = builtins.removeAttrs spec reservedHostAttrs;
      };
      unknownLayers = lib.filter (l: !(layers' ? ${l})) host.layers;
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
      inherit (host) system importance layers;
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

  layerKind = layerName: layers'.${layerName}.kind or "apps";

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
          services = def.services or { };
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
      ];
      config = {
        ftl.meta = {
          environment = name;
          inherit repo;
          host = hostName;
          attr = hostName;
          inherit (host) importance system layers;
        };
        ftl.layers.installed = lib.genAttrs host.layers (l: {
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

  specialArgs' = specialArgs // {
    inherit
      profiles
      homes
      static
      peers
      ;
  };

  # The exact nixosSystem arguments of every host (also attached to each
  # configuration as `ftlArgs`, e.g. for building VM tests from a host).
  systemArgs = builtins.mapAttrs (hostName: host: {
    modules =
      sharedModules
      ++ ftlModules
      ++ loader.collectPaths nixosModules
      ++ host.modules
      ++ [ (metaModule hostName host) ];
    specialArgs = specialArgs';
  }) hosts';

  nixosConfigurations = builtins.mapAttrs (
    _: a: nixpkgs.lib.nixosSystem a // { ftlArgs = a; }
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
# Validate every host spec eagerly (cheap; no NixOS evaluation involved).
assert builtins.all builtins.isAttrs (builtins.attrValues hosts');
{
  inherit
    nixosConfigurations
    nixosModules
    nixosProfiles
    nixosLayers
    checks
    manifestEntries
    peers
    ;
  hosts = hosts';
}
