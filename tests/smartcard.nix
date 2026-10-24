# fleet.smartcard on real machines: both have QEMU's emulated CCID reader
# (usb-ccid, 08e6:4433, which libccid drives). `reader` registers it and sees
# it through pcscd; `other` registers a different key and sees nothing, the
# reader ignored through the udev filter; scdaemon goes through pcscd, and an
# attended host gets touch notifications. (What only evaluation decides, the
# AGENTS.md text, ssh blocks and Nix defaults, is in unit-agents and
# unit-fleet.)
{
  pkgs,
  lib,
  ftl,
  nixpkgs,
  ...
}:
let
  fleet = ftl.lib.mkNixos {
    inherit nixpkgs;
    name = "sc";
    smartcard.readers.qemu = {
      vendor = "08e6";
      product = "4433";
      description = "QEMU usb-ccid";
    };
    hosts = {
      reader = { };
      other = {
        smartcard = {
          fleetReaders = false;
          readers.yk = {
            vendor = "1050";
            product = "0407";
          };
        };
      };
    };
  };

  args = host: fleet.nixosConfigurations.${host}.fleetArgs;

  node =
    host:
    { lib, ... }:
    {
      imports = (args host).modules;
      networking.hostName = lib.mkForce host;
      # a USB controller with the emulated reader on it
      virtualisation.qemu.options = [
        "-device qemu-xhci,id=xhci"
        "-device usb-ccid,bus=xhci.0"
      ];
    };
in
pkgs.testers.runNixOSTest {
  name = "ftl-smartcard";

  # the special arguments differ only in fleet.self, which nothing here reads
  node.specialArgs = (args "reader").specialArgs;
  node.pkgsReadOnly = false;

  nodes.reader = node "reader";
  nodes.other = node "other";

  testScript = ''
    start_all()
    for m in (reader, other):
        m.wait_for_unit("multi-user.target")

    def usb_ignore(m):
        dev = m.succeed("grep -l 08e6 /sys/bus/usb/devices/*/idVendor").strip().rsplit("/", 1)[0]
        return m.succeed(f"udevadm info -q property -p {dev} | sed -n 's/^PCSCLITE_IGNORE=//p'").strip()

    with subtest("registered: pcscd offers the reader"):
        assert usb_ignore(reader) == "0", usb_ignore(reader)
        reader.wait_until_succeeds("opensc-tool -l | grep -qi gemalto", timeout=60)

    with subtest("not registered: pcscd ignores it"):
        assert usb_ignore(other) == "1", usb_ignore(other)
        out = other.succeed("opensc-tool -l 2>&1 || true")
        assert "emalto" not in out, out

    with subtest("gpg goes through pcscd"):
        reader.succeed("grep -qx disable-ccid /etc/gnupg/scdaemon.conf")

    with subtest("attended: touch notifications in graphical sessions"):
        reader.succeed("test -e /etc/systemd/user/yubikey-touch-detector.service")
  '';
}
