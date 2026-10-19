# Secret stores and who can read them (`fleet.sops`): the fleet's
# nixos/secrets.yaml is for every host and the admins, its nixos/identity.yaml
# for the admins; a host's secrets.yaml is for the host and the admins, its
# identity.yaml for the admins; a service's secrets.yaml for its hosts, the
# admins and the users listing it; a user's for that user. Recipients are sops keys (pgp fingerprints, age recipients)
# and SSH host keys still to be converted with ssh-to-age; a host with a
# sops.age is a recipient by that, else by its ssh.pub.
ctx:
let
  inherit (ctx)
    lib
    src
    root'
    hosts'
    services'
    users'
    peers
    ;

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
    lib.optional
      (
        dir != null
        &&
          recipients != {
            pgp = [ ];
            age = [ ];
            ssh = [ ];
          }
      )
      {
        inherit kind owner recipients;
        path =
          assert lib.assertMsg (
            root' != null
          ) "ftl: mkNixos needs `root` (the repository) to name the store ${toString dir}/${file}";
          lib.removePrefix (toString root' + "/") (toString dir) + "/${file}";
      };

  stores =
    # the fleet's own: nixos/secrets.yaml for every host and the admins,
    # nixos/identity.yaml for the admins
    store "fleet" null src "secrets.yaml" (recipientsOf {
      hostNames = builtins.attrNames hosts';
      userNames = admins;
    })
    ++ store "fleet-identity" null src "identity.yaml" (recipientsOf {
      userNames = admins;
    })
    ++ lib.concatLists (
      lib.mapAttrsToList (
        hostName: host:
        store "host" hostName host.dir "secrets.yaml" (recipientsOf {
          hostNames = [ hostName ];
          userNames = admins;
        })
        ++ store "identity" hostName host.dir "identity.yaml" (recipientsOf {
          userNames = admins;
        })
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
        userName: user:
        store "user" userName user.dir "secrets.yaml" (recipientsOf {
          userNames = [ userName ];
        })
      ) users'
    );
in
{
  sops.stores = lib.sort (a: b: a.path < b.path) stores;
}
