# Services: nixos/services/<name>/ discovered, explicit specs merged over
# them, normalized, and their modules with the `service` argument.
#
# service.nix is metadata, not a module: { hosts; } or { roles.<r>.hosts; },
# layers the service brings to its hosts, and free-form data. Its modules are
# imported on its hosts only; home.nix is left to the home side.
ctx:
let
  inherit (ctx)
    lib
    loader
    dir
    exists
    services
    ;

  discovered =
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

  # Attributes of a service spec that ftl interprets; everything else is data.
  reserved = [
    "name"
    "hosts"
    "roles"
    "layers"
    "modules"
    "dir"
  ];

  normalize =
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
        data = builtins.removeAttrs spec reserved;
      };
      unknownHosts = lib.filter (h: !(ctx.hostSpecs ? ${h})) service.hosts;
      unknownLayers = lib.filter (l: !(ctx.layers' ? ${l})) service.layers;
    in
    assert lib.assertMsg (!(spec ? name))
      "ftl: service '${serviceName}' sets reserved attribute 'name' (the directory name is the service name)";
    assert lib.assertMsg (
      unknownHosts == [ ]
    ) "ftl: service '${serviceName}' names undefined hosts: ${toString unknownHosts}";
    assert lib.assertMsg (
      unknownLayers == [ ]
    ) "ftl: service '${serviceName}' uses undefined layers: ${toString unknownLayers}";
    service;
in
rec {
  serviceSpecs =
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
        services
      ];

  services' = builtins.mapAttrs normalize serviceSpecs;

  # The services a host runs, and its roles in one of them.
  servicesOf = hostName: lib.filterAttrs (_: s: builtins.elem hostName s.hosts) services';
  rolesOf =
    hostName: service:
    builtins.attrNames (lib.filterAttrs (_: r: builtins.elem hostName r.hosts) service.roles);

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
          # on a host its roles; elsewhere (nixosServices in another
          # configuration) those of the configuration's fleet.meta.host, if any
          role = rolesOf (if hostName != null then hostName else args.config.fleet.meta.host or null) service;
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
}
