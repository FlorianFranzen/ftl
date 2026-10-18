# mkUsers, called directly: user.nix is metadata, the key files are parsed.
{
  lib,
  ftl,
  fixture,
  check,
  ...
}:
let
  u =
    (ftl.lib.mkUsers {
      src = fixture + "/users";
      inherit lib;
    }).users;
in
check "unit-users" (
  lib.runTests {
    testUsers = {
      expr = builtins.attrNames u;
      expected = [
        "alice"
        "bob"
      ];
    };

    # comments and blank lines in the key files are skipped
    testKeys = {
      expr = u.alice.keys;
      expected = {
        ssh = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAlice000000000000000000000000000000000000000 alice@laptop"
        ];
        pgp = [ ];
        age = [ "age1alice00000000000000000000000000000000000000000000000000000" ];
      };
    };

    testMeta = {
      expr = {
        inherit (u.alice) admin uid home;
        bob = {
          inherit (u.bob) services groups;
        };
        dir = u.bob.dir;
      };
      expected = {
        admin = true;
        uid = 1000;
        home = "desktop-dark";
        bob = {
          services = [ "web" ];
          groups = [ "video" ];
        };
        dir = fixture + "/users/bob";
      };
    };
  }
)
