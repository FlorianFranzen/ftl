# Users: the specs of mkUsers resolved against the hosts and services, and
# the home each user gets on each host (with the NixOS side its profiles
# need, the companions of mkHome).
#
# An admin is on every host unless `hosts` says otherwise; anyone else is on
# the hosts listed and on the hosts of the services listed. `home` is a
# configuration name, or { default?; <host>?; } for one per host (a null
# entry means none on that host).
ctx:
let
  inherit (ctx)
    lib
    users
    homes
    homeCompanions
    ;

  reserved = [
    "name"
    "admin"
    "hosts"
    "services"
    "home"
    "uid"
    "groups"
    "shell"
    "description"
    "keys"
    "dir"
  ];

  normalize =
    userName: spec:
    let
      admin = spec.admin or false;
      user = {
        inherit admin;
        services = spec.services or [ ];
        hosts = lib.unique (
          (if spec ? hosts then spec.hosts else lib.optionals admin (builtins.attrNames ctx.hostSpecs))
          ++ lib.concatMap (s: ctx.services'.${s}.hosts) (spec.services or [ ])
        );
        home = spec.home or null;
        uid = spec.uid or null;
        groups = spec.groups or [ ];
        # the account's login shell (a package name) and full name
        shell = spec.shell or null;
        description = spec.description or null;
        keys = {
          ssh = [ ];
          pgp = [ ];
          age = [ ];
        }
        // (spec.keys or { });
        dir = spec.dir or null;
        data = builtins.removeAttrs spec reserved;
      };
      unknownHosts = lib.filter (h: !(ctx.hostSpecs ? ${h})) (spec.hosts or [ ]);
      unknownServices = lib.filter (s: !(ctx.serviceSpecs ? ${s})) user.services;
      homeNames =
        if user.home == null then
          [ ]
        else if builtins.isString user.home then
          [ user.home ]
        else
          lib.filter (h: h != null) (builtins.attrValues user.home);
      unknownHomes = lib.filter (h: !(homes ? ${h})) homeNames;
    in
    assert lib.assertMsg (
      !(spec ? name)
    ) "ftl: user '${userName}' sets reserved attribute 'name' (the directory name is the user name)";
    assert lib.assertMsg (
      unknownHosts == [ ]
    ) "ftl: user '${userName}' names undefined hosts: ${toString unknownHosts}";
    assert lib.assertMsg (
      unknownServices == [ ]
    ) "ftl: user '${userName}' names undefined services: ${toString unknownServices}";
    assert lib.assertMsg (unknownHomes == [ ] || homes != { })
      "ftl: user '${userName}' wants a home configuration, but there are none (no home/ folder, or no home-manager input)";
    assert lib.assertMsg (
      unknownHomes == [ ]
    ) "ftl: user '${userName}' wants home configurations that do not exist: ${toString unknownHomes}";
    lib.warnIf (user.hosts != [ ] && user.keys.ssh == [ ])
      "ftl: user '${userName}' has an account on ${toString (builtins.length user.hosts)} host(s) but no SSH key (ssh.pub)"
      user;
in
rec {
  users' = builtins.mapAttrs normalize users;

  usersOf = hostName: lib.filterAttrs (_: u: builtins.elem hostName u.hosts) users';

  # The home configuration a user gets on a host.
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
        shell
        description
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
}
