# Hosts: nixos/hosts/<name>/ discovered, explicit specs merged over them,
# normalized, and `fleet.hosts` (every host's metadata as every host sees it).
#
# host.nix is metadata, not a module; its reserved attributes are below,
# everything else is free-form data. Every <name>.pub next to it is a public
# key of the host (keys.<name>), sops.age an age recipient used instead of
# the SSH host key (keys.age).
ctx:
let
  inherit (ctx)
    lib
    loader
    dir
    exists
    hosts
    ;

  discovered =
    if !exists "hosts" then
      { }
    else
      lib.mapAttrs (
        hostName: _:
        let
          hostDir = dir "hosts/${hostName}";
          meta = if builtins.pathExists (hostDir + "/host.nix") then import (hostDir + "/host.nix") else { };
          key =
            file: attr:
            let
              value = ctx.readKey (hostDir + "/${file}");
            in
            lib.optionalAttrs (builtins.pathExists (hostDir + "/${file}") && value != null) {
              ${attr} = value;
            };
          pubFiles = lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".pub" n) (
            builtins.readDir hostDir
          );
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

  importances = [
    "required"
    "optional"
    "ignored"
  ];

  # Attributes of a host spec that ftl interprets; everything else is data.
  reserved = [
    "name"
    "system"
    "importance"
    "modules"
    "layers"
    "services"
    "users"
    "dir"
    "generators"
    "smartcard"
  ];

  normalize =
    hostName: spec:
    let
      ownServices = ctx.servicesOf hostName;
      host = {
        system = spec.system or "x86_64-linux";
        importance = spec.importance or "required";
        modules = spec.modules or [ ];
        # its own layers, and those of its services
        layers = lib.unique (
          (spec.layers or [ ]) ++ lib.concatMap (s: s.layers) (builtins.attrValues ownServices)
        );
        services = builtins.attrNames ownServices;
        users = builtins.attrNames (ctx.usersOf hostName);
        generators = spec.generators or [ "host-keys" ];
        smartcard = ctx.normalizeSmartcard hostName (spec.smartcard or { });
        dir = spec.dir or null;
        data = builtins.removeAttrs spec reserved;
      };
      unknownLayers = lib.filter (l: !(ctx.layers' ? ${l})) (spec.layers or [ ]);
      unknownGenerators = lib.filter (g: !(ctx.generators ? ${g})) host.generators;
      fleetGenerators = lib.filter (
        g: ctx.generators ? ${g} && ctx.generators.${g}.scope == "fleet"
      ) host.generators;
    in
    assert lib.assertMsg (
      !(spec ? name)
    ) "ftl: host '${hostName}' sets reserved attribute 'name' (the directory name is the host name)";
    assert lib.assertMsg (builtins.elem host.importance importances)
      "ftl: host '${hostName}' has invalid importance '${host.importance}'";
    assert lib.assertMsg (
      unknownLayers == [ ]
    ) "ftl: host '${hostName}' uses undefined layers: ${toString unknownLayers}";
    assert lib.assertMsg (
      !lib.hasPrefix "layer-" hostName
    ) "ftl: host name '${hostName}' collides with layer check names (nixos-layer-*)";
    assert lib.assertMsg (
      unknownGenerators == [ ]
    ) "ftl: host '${hostName}' uses undefined generators: ${toString unknownGenerators}";
    assert lib.assertMsg (fleetGenerators == [ ])
      "ftl: host '${hostName}' lists fleet generators (they run once, with `fleetl fleet generate`): ${toString fleetGenerators}";
    host;
in
rec {
  # A public key file's value: its first line that is not a comment (an SSH
  # key, an age recipient), or, for a PEM file (a certificate), every PEM
  # line, as the PEM text.  null for an empty file.
  readKey =
    path:
    let
      lines = lib.filter (l: l != "" && !lib.hasPrefix "#" l) (
        map lib.trim (lib.splitString "\n" (builtins.readFile path))
      );
    in
    if lines == [ ] then
      null
    else if lib.hasPrefix "-----BEGIN " (builtins.head lines) then
      lib.concatMapStrings (l: l + "\n") lines
    else
      builtins.head lines;

  # specs: discovered, explicit ones merged over them (modules appended)
  hostSpecs =
    lib.zipAttrsWith
      (
        _: specs:
        let
          a = builtins.head specs;
          b = if builtins.length specs > 1 then builtins.elemAt specs 1 else { };
        in
        a // b // { modules = (a.modules or [ ]) ++ (b.modules or [ ]); }
      )
      [
        discovered
        hosts
      ];

  hosts' = builtins.mapAttrs normalize hostSpecs;

  # Every host's metadata, as seen by every host, itself included (`fleet.hosts`).
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
        smartcard
        ;
    }
  ) hosts';
}
