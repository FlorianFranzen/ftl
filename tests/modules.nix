# All ftl NixOS modules together on one host produced by mkFlake from the
# full fixture: builder, cache, client, layers and the flake integration.
{
  pkgs,
  lib,
  ftl,
  fixture,
  inputs,
  ...
}:
let
  f = ftl.lib.mkFlake {
    src = fixture;
    inherit inputs;
    name = "modules";
    nixos.extraProfiles.extra.only = {
      environment.etc."extra-only".text = "extra";
    };
    home = {
      bases.desktop = [
        "terminal"
        "desktop"
      ];
      username = "alice";
    };
  };
  alpha = f.nixosConfigurations.alpha.ftlArgs;
in
pkgs.testers.runNixOSTest {
  name = "ftl-modules";

  # build the node from exactly the modules mkFlake used for host alpha
  node.specialArgs = alpha.specialArgs;
  node.pkgsReadOnly = false;

  nodes.machine =
    { lib, ... }:
    {
      imports = alpha.modules;

      networking.hostName = lib.mkForce "machine";

      ftl.builder.enable = true;
      ftl.cache = {
        enable = true;
        cacheDir = "/var/lib/ftl-cache";
      };
      ftl.client = {
        enable = true;
        statusUrl = "http://localhost:8080/status/fixture.json";
      };
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # package set: local overlay package from pkgs/
    machine.succeed("hello-ftl | grep -q 'hello from ftl'")

    # static file placed by the host's own config (ftl installs nothing itself)
    assert machine.succeed("cat /etc/marker").strip() == "marker"

    # profiles: local and extra profiles both applied
    assert machine.succeed("cat /etc/profile-source").strip() == "local"
    machine.succeed("test -e /etc/extra-only")

    # layers module: updater unit and generator are installed
    machine.succeed("systemctl cat ftl-layers-update.service")
    machine.succeed("test -e /etc/systemd/system-generators/ftl-layers")
    machine.succeed("command -v ftl-layers")

    # builder + cache + client coexist
    machine.wait_for_unit("nginx.service")
    machine.succeed("id ftl")
    machine.succeed("echo '{}' > /var/lib/ftl-status/fixture.json")
    machine.succeed("curl -fsS http://localhost:8080/status/fixture.json")
    machine.succeed("command -v ftl-status")

    # flake integration: registry and revision from the flake
    machine.succeed("grep -q abc1234 /run/current-system/configuration-revision || nixos-version --configuration-revision | grep -q abc1234")
  '';
}
