# Smartcard readers: what mkFlake's `smartcard` and host.nix say about them,
# validated and resolved.
#
# Readers are registered for the whole fleet (mkFlake's `smartcard`) or per
# host (`smartcard` in host.nix): { presence?; readers.<name> = { vendor;
# product?; serial?; port?; description?; }; fleetReaders?; }. A host's entry
# in `fleet.hosts` carries the result (`smartcard`, or null when no reader is
# registered there); fleet.smartcard binds pcscd to exactly those.
ctx:
let
  inherit (ctx) lib smartcard;
  inherit (import ../smartcard.nix { inherit lib; })
    presences
    fleetAttrs
    hostAttrs
    readerAttrs
    isUsbId
    isUdevValue
    ;

  normalizeReader =
    where: readerName: r:
    let
      reader = {
        vendor = r.vendor or null;
        product = r.product or null;
        serial = r.serial or null;
        port = r.port or null;
        description = r.description or null;
      };
      unknown = lib.subtractLists readerAttrs (builtins.attrNames r);
    in
    assert lib.assertMsg (unknown == [ ])
      "ftl: ${where}: reader '${readerName}' has unknown attributes: ${toString unknown} (known: ${toString readerAttrs})";
    assert lib.assertMsg (isUsbId reader.vendor)
      "ftl: ${where}: reader '${readerName}' needs `vendor`, the USB vendor id as four lower-case hex digits (e.g. \"1050\")";
    assert lib.assertMsg (
      reader.product == null || isUsbId reader.product
    ) "ftl: ${where}: reader '${readerName}' has `product` that is not four lower-case hex digits";
    assert lib.assertMsg (isUdevValue reader.serial && isUdevValue reader.port)
      "ftl: ${where}: reader '${readerName}' has a `serial` or `port` with a quote, backslash or newline";
    reader;

  fleetUnknown = lib.subtractLists fleetAttrs (builtins.attrNames smartcard);
  fleetPresence = smartcard.presence or "attended";
  # checked with every host, so a typo there never goes unnoticed
  fleetValid =
    assert lib.assertMsg (fleetUnknown == [ ])
      "ftl: mkFlake smartcard has unknown attributes: ${toString fleetUnknown} (known: ${toString fleetAttrs})";
    assert lib.assertMsg (builtins.elem fleetPresence presences)
      "ftl: mkFlake smartcard presence '${fleetPresence}' is not one of: ${toString presences}";
    true;
  fleetReaders = lib.mapAttrs (normalizeReader "mkFlake smartcard") (smartcard.readers or { });

in
{
  # A host's smartcard setup: the fleet's readers (unless `fleetReaders = false`)
  # and its own; null when none is registered, which leaves the module off.
  normalizeSmartcard =
    hostName: spec:
    let
      where = "host '${hostName}'";
      own = lib.mapAttrs (normalizeReader where) (spec.readers or { });
      readers = (if spec.fleetReaders or true then fleetReaders else { }) // own;
      presence = spec.presence or fleetPresence;
      unknown = lib.subtractLists hostAttrs (builtins.attrNames spec);
    in
    assert fleetValid;
    if spec == null then
      null
    else
      assert lib.assertMsg (builtins.isAttrs spec)
        "ftl: ${where}: `smartcard` must be an attribute set or null";
      assert lib.assertMsg (unknown == [ ])
        "ftl: ${where}: `smartcard` has unknown attributes: ${toString unknown} (known: ${toString hostAttrs})";
      assert lib.assertMsg (builtins.elem presence presences)
        "ftl: ${where}: smartcard presence '${presence}' is not one of: ${toString presences}";
      if readers == { } then null else { inherit presence readers; };
}
