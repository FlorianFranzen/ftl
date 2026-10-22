# fleetl service move, end to end: an admin machine runs fleetl against a
# repository whose service `web` runs on `src` (btrfs) and moves it to `dst`
# (ZFS).  fleetl's evaluations are answered by a stub from the nodes' own
# configurations; everything else is real: ssh to the hosts as root,
# fleet-state on them, the stream between them through the admin machine.
# Deploying the moved configuration is a switch to a specialisation: on dst
# one that declares web and api, on src one without them.  src backs up to
# `box` over sftp, so that api can move --via backup: dst restores it from
# src's repository with src's credentials, handed over for the restore.
{ pkgs, ftl }:
let
  lib = pkgs.lib;
  sshKeys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;

  # the service web (with a state and a data entry) and api, present unless
  # test.web / test.api say otherwise
  services =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      options.test = {
        web = lib.mkOption { default = false; };
        api = lib.mkOption { default = false; };
      };
      config = lib.mkMerge [
        (lib.mkIf config.test.web {
          fleet.state = {
            web = {
              path = "/var/lib/web";
              units = [ "web" ];
              service = "web";
            };
            web-media = {
              path = "/srv/web-media";
              kind = "data";
              service = "web";
            };
          };
          systemd.services.web = {
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              User = "web";
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStartPre = "+${pkgs.coreutils}/bin/chown web:web /var/lib/web";
            };
            script = "date >> /var/lib/web/log";
          };
        })
        (lib.mkIf config.test.api {
          fleet.state.api = {
            path = "/var/lib/api";
            units = [ "api" ];
            service = "api";
          };
          systemd.services.api = {
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = "date >> /var/lib/api/log";
          };
        })
      ];
    };

  host =
    name:
    { pkgs, ... }:
    {
      imports = [
        ftl.nixosModules.state
        ftl.nixosModules.backup
        services
      ];
      networking.hostName = name;
      virtualisation.emptyDiskImages = [ 512 ];
      environment.systemPackages = [
        pkgs.btrfs-progs
        pkgs.attr
      ];
      services.openssh = {
        enable = true;
        hostKeys = [
          {
            path = "/etc/ssh/test_host_key";
            type = "ed25519";
          }
        ];
      };
      environment.etc."ssh/test_host_key" = {
        source = sshKeys.snakeOilEd25519PrivateKey;
        mode = "0600";
      };
      users.users.root.openssh.authorizedKeys.keys = [ sshKeys.snakeOilPublicKey ];
      # every host with backups trusts the box (as a fleet would pin it)
      programs.ssh.knownHosts.box = {
        hostNames = [ "box" ];
        publicKey = sshKeys.snakeOilEd25519PublicKey;
      };
      users.users.web = {
        isSystemUser = true;
        group = "web";
        uid = 991;
      };
      users.groups.web.gid = 991;
    };

  # what fleetl evaluates, from the nodes' configurations
  stub =
    nodes:
    let
      state =
        h:
        pkgs.writeText "${h}-state.json" (
          builtins.toJSON (
            lib.mapAttrs (_: e: {
              inherit (e)
                kind
                path
                service
                backup
                ;
            }) nodes.${h}.config.fleet.state
          )
        );
      hosts = pkgs.writeText "hosts.json" (
        builtins.toJSON (
          lib.genAttrs [ "src" "dst" ] (h: {
            name = h;
            importance = "required";
            keys.ssh = sshKeys.snakeOilEd25519PublicKey;
          })
        )
      );
    in
    pkgs.writeShellScriptBin "nix" ''
      case "$*" in
        "eval --json .#fleet.hosts") cat ${hosts} ;;
        # the services as their service.nix say now
        "eval --json .#fleet.services")
          for d in nixos/services/*/; do
            s="$(basename "$d")"
            ${pkgs.nix}/bin/nix-instantiate --readonly-mode --eval --strict --json "$d/service.nix" |
              ${pkgs.jq}/bin/jq --arg s "$s" '{ ($s): ({ name: $s, layers: [], roles: { default: { hosts: .hosts } } } + .) }'
          done | ${pkgs.jq}/bin/jq -s 'add'
          ;;
        "eval --json .#fleet.sops") echo '{ "stores": [], "extraRules": [] }' ;;
        "eval --json .#nixosConfigurations.\"src\".config.fleet.state --apply "*) cat ${state "src"} ;;
        "eval --json .#nixosConfigurations.\"dst\".config.fleet.state --apply "*) cat ${state "dst"} ;;
        "eval --json .#nixosConfigurations.\"src\".config.fleet.backup.enable") echo true ;;
        "eval --json .#nixosConfigurations.\"src\".config.fleet.storage.tool.enable") echo true ;;
        "eval --json .#nixosConfigurations.\"dst\".config.fleet.backup.enable") echo false ;;
        # this repository has no deploy output
        "eval --json .#deploy --apply "*) echo "error: flake does not provide attribute 'deploy'" >&2; exit 1 ;;
        *) echo "stub nix: no $*" >&2; exit 1 ;;
      esac
    '';
in
pkgs.testers.runNixOSTest {
  name = "ftl-move";

  nodes.src =
    { ... }:
    {
      imports = [ (host "src") ];
      fleet.storage.btrfsDevice = "/dev/vdb";
      test.web = true;
      test.api = true;
      fleet.backup = {
        enable = true;
        repositories.state = {
          repository = "opendal:sftp";
          options = {
            endpoint = "ssh://backup@box:22";
            user = "backup";
            key = "/etc/backup-key";
            root = "/srv/backup/state";
            known_hosts_strategy = "Strict";
          };
        };
        passwordFile = "/etc/backup-password";
        credentialFiles.ssh-key = "/etc/backup-key";
        packages = [ pkgs.openssh ];
      };
      environment.etc."backup-password".text = "test";
      environment.etc."backup-key" = {
        source = sshKeys.snakeOilPrivateKey;
        mode = "0600";
      };
      # deploying the repository after the move: web and api are gone
      specialisation.moved.configuration.test = {
        web = lib.mkForce false;
        api = lib.mkForce false;
      };
    };

  nodes.dst =
    { ... }:
    {
      imports = [ (host "dst") ];
      boot.supportedFilesystems.zfs = true;
      boot.zfs.forceImportRoot = false;
      networking.hostId = "8425e349";
      fleet.storage.zfsPool = "tank";
      # deploying the repository after the move: web and api are here
      specialisation.moved.configuration.test = {
        web = true;
        api = true;
      };
    };

  nodes.box =
    { ... }:
    {
      services.openssh = {
        enable = true;
        hostKeys = [
          {
            path = "/etc/ssh/test_host_key";
            type = "ed25519";
          }
        ];
      };
      environment.etc."ssh/test_host_key" = {
        source = sshKeys.snakeOilEd25519PrivateKey;
        mode = "0600";
      };
      users.users.backup = {
        isNormalUser = true;
        home = "/srv/backup";
        createHome = true;
        openssh.authorizedKeys.keys = [ sshKeys.snakeOilPublicKey ];
      };
    };

  nodes.admin =
    { pkgs, nodes, ... }:
    {
      environment.systemPackages = [
        (pkgs.writeShellScriptBin "fleetl" ''
          export PATH=${stub nodes}/bin:$PATH
          exec ${pkgs.bash}/bin/bash -o errexit -o nounset -o pipefail ${../scripts/fleetl.sh} "$@"
        '')
      ]
      ++ (with pkgs; [
        jq
        yq-go
        sops
        ssh-to-age
        git
        gawk
        diffutils
        util-linux
      ]);
      environment.etc."admin-key" = {
        source = sshKeys.snakeOilPrivateKey;
        mode = "0600";
      };
    };

  testScript = ''
    import json
    start_all()
    for m in [src, dst, admin, box]:
        m.wait_for_unit("multi-user.target")
    for m in [src, dst, box]:
        m.wait_for_open_port(22)

    src.succeed("mkfs.btrfs -f /dev/vdb")
    src.succeed("systemctl start web.service api.service $(systemd-escape --path --suffix=mount /srv/web-media)")
    src.succeed("head -c 1M /dev/urandom > /var/lib/web/blob && chown web:web /var/lib/web/blob")
    src.succeed("setfattr -n user.tag -v moved /var/lib/web/blob")
    src.succeed("echo media > /srv/web-media/film")
    src.succeed("chmod 0750 /var/lib/web")
    src.succeed("chown 991:991 /var/lib/api && chmod 0710 /var/lib/api")
    src.succeed("fleet-state init")
    dst.succeed("zpool create -O mountpoint=none tank /dev/vdb")
    blob = src.succeed("sha256sum < /var/lib/web/blob")

    admin.succeed("install -D -m 0600 /etc/admin-key /root/.ssh/id_rsa")
    admin.succeed(
        "mkdir -p /repo/nixos/services/web /repo/nixos/services/api && cd /repo && git init -q"
        " && echo '{ hosts = [ \"src\" ]; port = 8080; }' > nixos/services/web/service.nix"
        " && echo '{ hosts = [ \"src\" ]; }' > nixos/services/api/service.nix"
        " && git add -A && git -c user.name=t -c user.email=t@t commit -qm init"
    )

    def fleetl(args):
        return admin.succeed(f"cd /repo && fleetl {args} 2>&1")

    def fleetl_fails(args):
        admin.fail(f"cd /repo && fleetl {args}")

    with subtest("moves that make no sense are refused"):
        fleetl_fails("service move web src --yes")
        fleetl_fails("service move nosuch dst --yes")
        fleetl_fails("service move web nosuch --yes")

    with subtest("a move that fails is undone"):
        # something in the way on dst
        dst.succeed("zfs create -p -o mountpoint=legacy tank/apps/api")
        fleetl_fails("service move api dst --yes")
        admin.succeed("grep -q '\"src\"' /repo/nixos/services/api/service.nix")
        src.succeed("systemctl is-active api.service")
        src.succeed("touch /var/lib/api/still-writable")
        # what was in the way is still there, nothing else came
        dst.succeed("zfs list tank/apps/api")
        dst.fail("zfs list tank/apps/api.incoming")
        dst.succeed("zfs destroy tank/apps/api")
        fleetl_fails("state drop src api state")  # declared and in use

    def web_snapshots():
        snaps = json.loads(src.succeed("rustic -P state snapshots --json --filter-label web"))
        return sum(len(g["snapshots"]) for g in snaps)

    with subtest("a move failing after it placed an entry drops that one again, and only that"):
        # web-media is in the way on dst; web goes first and is placed
        dst.succeed("zfs create -p -o mountpoint=legacy tank/data/web-media")
        fleetl_fails("service move web dst --yes")
        admin.succeed("grep -q '\"src\"' /repo/nixos/services/web/service.nix")
        dst.fail("zfs list tank/apps/web")
        dst.succeed("zfs list tank/data/web-media")  # what was there stays
        src.succeed("systemctl is-active web.service")
        src.succeed("touch /var/lib/web/still-writable")
        dst.succeed("zfs destroy tank/data/web-media")
        # its last backup was made before the failure
        assert web_snapshots() == 1

    with subtest("a move without its data and without a backup; the data copied later"):
        runs = int(src.succeed("wc -l < /var/lib/web/log"))
        out = fleetl("service move web dst --without-data --no-backup --yes")
        print(out)
        assert "fleetl state copy src dst <entry> <kind>" in out, out
        admin.succeed("grep -q '\"dst\"' /repo/nixos/services/web/service.nix")
        admin.fail("grep -q '\"src\"' /repo/nixos/services/web/service.nix")
        admin.succeed("grep -q 'port = 8080' /repo/nixos/services/web/service.nix")
        admin.succeed("test -f /repo/.sops.yaml")
        assert web_snapshots() == 1
        # the source: stopped, blocked; what moved is read-only, the data is not
        src.fail("systemctl is-active web.service")
        src.fail("systemctl start web.service")
        src.fail("touch /var/lib/web/x")
        src.succeed("touch /srv/web-media/still-writable && rm /srv/web-media/still-writable")
        datasets = dst.succeed("zfs list -H -o name,mountpoint -r tank")
        assert "tank/apps/web\tlegacy" in datasets, datasets
        assert "web-media" not in datasets, datasets
        assert "incoming" not in datasets, datasets
        # what was just placed on dst is no frozen copy: drop refuses it
        fleetl_fails("state drop dst web state")
        dst.succeed("zfs list tank/apps/web")
        # the data, copied when it suits
        fleetl("state copy src dst web-media data")
        datasets = dst.succeed("zfs list -H -o name,mountpoint -r tank")
        assert "tank/data/web-media\tlegacy" in datasets, datasets
        # api stays where it was
        src.succeed("systemctl is-active api.service")

    with subtest("a move through the backup: dst restores from src's repository"):
        src.succeed("echo api-data > /var/lib/api/marker")
        out = fleetl("service move api dst --via backup --yes")
        print(out)
        assert "restored on dst from that backup" in out, out
        admin.succeed("grep -q '\"dst\"' /repo/nixos/services/api/service.nix")
        src.fail("touch /var/lib/api/y")
        dst.succeed("zfs list tank/apps/api")
        dst.succeed("mkdir -p /mnt/api && mount -t zfs tank/apps/api /mnt/api")
        dst.succeed("grep -qx api-data /mnt/api/marker")
        # the top directory as it was (rustic does not keep it; the backup's tag does)
        assert dst.succeed("stat -c %u:%a /mnt/api").strip() == "991:710"
        dst.succeed("umount /mnt/api")
        # the credentials did not stay, nor a cache of src's repository
        dst.fail("ls -d /run/fleet-state.??????")
        dst.fail("grep -rqs -e 'PRIVATE KEY' -e 'backup-key' /run /root /var/cache /tmp")
        src.fail("ls -d /run/fleet-state.??????")
        dst.fail("test -e /root/.cache/rustic")
        # it came from the box, as src's last backup of it
        box.succeed("test -d /srv/backup/state/snapshots")

    with subtest("a reboot of the source before its deploy does not start what moved"):
        src.shutdown()
        src.start()
        src.wait_for_unit("multi-user.target")
        src.fail("systemctl is-active web.service")
        src.fail("systemctl start web.service")
        src.fail("systemctl start api.service")
        src.fail("touch /var/lib/web/x")
        src.wait_for_open_port(22)

    with subtest("deployed, the target runs the service on what it received"):
        dst.succeed("/run/current-system/specialisation/moved/bin/switch-to-configuration test")
        dst.succeed("systemctl is-active web.service")
        assert dst.succeed("sha256sum < /var/lib/web/blob") == blob
        assert dst.succeed("stat -c %u:%g /var/lib/web/blob").strip() == "991:991"
        assert dst.succeed("stat -c %u:%a /var/lib/web").strip() == "991:750"
        assert dst.succeed("getfattr --only-values -n user.tag /var/lib/web/blob").strip() == "moved"
        dst.succeed("grep -qx media /srv/web-media/film")
        # src's runs and dst's first one
        assert int(dst.succeed("wc -l < /var/lib/web/log")) == runs + 1
        assert dst.succeed("zfs get -H -o value com.sun:auto-snapshot tank/apps/web").strip() == "true"
        dst.succeed("systemctl is-active api.service")
        dst.succeed("grep -qx api-data /var/lib/api/marker")

    with subtest("deployed, the source lets go; the frozen copy is dropped"):
        # not before the deploy: a reboot meanwhile would bring it back empty
        fleetl_fails("state drop src api state")
        src.succeed("/run/current-system/specialisation/moved/bin/switch-to-configuration test")
        src.fail("mountpoint -q /var/lib/web")
        fleetl("state drop src web state")
        # the data that stayed was never frozen: only by force
        fleetl_fails("state drop src web-media data")
        fleetl("state drop src --force web-media data")
        fleetl("state drop src api state")
        src.succeed("mkdir -p /mnt/top && mount -o subvolid=5 /dev/vdb /mnt/top")
        src.succeed("test ! -e /mnt/top/@apps/web && test ! -e /mnt/top/@data/web-media && test ! -e /mnt/top/@apps/api")
        src.succeed("umount /mnt/top")
        src.fail("ls /run/systemd/system/web.service.d/*")
        src.fail("ls /run/systemd/system/api.service.d/*")
  '';
}
