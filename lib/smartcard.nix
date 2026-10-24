# What a smartcard reader registration is, shared by the metadata
# (lib/nixos/smartcards.nix), the module (modules/smartcard.nix) and the
# AGENTS.md text (lib/agents.nix), so the three cannot drift apart.
{ lib }:
rec {
  presences = [
    "attended"
    "headless"
  ];

  # attributes of mkFlake's `smartcard`, and of a host's
  fleetAttrs = [
    "presence"
    "readers"
  ];
  hostAttrs = fleetAttrs ++ [ "fleetReaders" ];

  # attributes of readers.<name>; `vendor` is required
  readerAttrs = [
    "vendor"
    "product"
    "serial"
    "port"
    "description"
  ];

  # USB vendor and product ids as lsusb prints them
  usbIdPattern = "[0-9a-f]{4}";
  isUsbId = s: builtins.isString s && builtins.match usbIdPattern s != null;

  # serial and port go between double quotes in a udev rule
  udevValuePattern = "[^\"\\\n]*";
  isUdevValue = s: s == null || (builtins.isString s && builtins.match udevValuePattern s != null);

  # `name` (USB vendor:product, serial …, port …): description
  readerText =
    name: r:
    "`${name}` (USB ${r.vendor}${lib.optionalString (r.product or null != null) ":${r.product}"}"
    + lib.optionalString (r.serial or null != null) ", serial ${r.serial}"
    + lib.optionalString (r.port or null != null) ", port ${r.port}"
    + ")"
    + lib.optionalString (r.description or null != null) ": ${r.description}";

  readersText = readers: lib.concatStringsSep "; " (lib.mapAttrsToList readerText readers);
}
