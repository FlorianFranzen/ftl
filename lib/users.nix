# mkUsers: users/ folder -> the fleet's users, as specs for mkNixos.
#
#   users/<name>/user.nix   metadata, not a module:
#                           { admin?; hosts?; services?; home?; uid?; groups?; ... }
#                           (further attributes are free-form user data)
#   users/<name>/ssh.pub    SSH public keys, one per line: login, sudo, deploy
#   users/<name>/sops.pgp   PGP fingerprints, one per line   } the user's sops
#   users/<name>/sops.age   age recipients, one per line     } recipients
#
# Where a user has an account follows from user.nix: an admin is on every host
# (with sudo), anyone else on the hosts listed and on the hosts of the services
# listed. mkNixos resolves that; this only reads the folder.
{ src, lib }:
let
  # Non-empty, non-comment lines of a file, or none when it does not exist.
  lines =
    file:
    if builtins.pathExists file then
      lib.filter (l: l != "" && !lib.hasPrefix "#" l) (
        map lib.trim (lib.splitString "\n" (builtins.readFile file))
      )
    else
      [ ];

  user =
    userName: _:
    let
      userDir = src + "/${userName}";
      meta = if builtins.pathExists (userDir + "/user.nix") then import (userDir + "/user.nix") else { };
    in
    assert lib.assertMsg (
      !(meta ? name)
    ) "ftl: user '${userName}' sets reserved attribute 'name' (the directory name is the user name)";
    assert lib.assertMsg (!(meta ? keys))
      "ftl: user '${userName}' sets reserved attribute 'keys' (keys come from ssh.pub, sops.pgp and sops.age)";
    meta
    // {
      dir = userDir;
      keys = {
        ssh = lines (userDir + "/ssh.pub");
        pgp = lines (userDir + "/sops.pgp");
        age = lines (userDir + "/sops.age");
      };
    };
in
{
  users = lib.mapAttrs user (lib.filterAttrs (_: t: t == "directory") (builtins.readDir src));
}
