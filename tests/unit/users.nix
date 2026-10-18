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
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHW437gdXlD8N84nBJqtbi36N1kia4RepapKRaxqlor6 alice"
        ];
        pgp = [ ];
        age = [ "age18jlex7sq6yufhk48ljzs5uzxrtazqrchddanezf7w5gl48nccv7sflpg7l" ];
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
