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
        dir = spec.dir or null;
        data = builtins.removeAttrs spec reserved;
      };
      unknownLayers = lib.filter (l: !(ctx.layers' ? ${l})) (spec.layers or [ ]);
      unknownGenerators = lib.filter (g: !(ctx.generatorFiles ? ${g})) host.generators;
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
    host;
in
rec {
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
        ;
    }
  ) hosts';
}
