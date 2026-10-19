# mkLayer: build an ftl layer - an independently versioned set of packages
# (kind "packages") or packages plus systemd units (kind "units") that a
# host installs as its own Nix profile under /nix/var/nix/profiles/layers/.
#
# Layout of the result:
#   bin/, share/, ...                 merged packages (buildEnv)
#   lib/systemd/system/<unit>         generated service units (units kind)
#   lib/systemd/system/<t>.wants/<u>  install links for WantedBy targets
#   share/ftl-layer/meta.json         { name, kind, units }
{
  pkgs,
  name,
  kind ? "packages",
  # list of packages, or a function pkgs -> list
  packages ? [ ],
  # units.<name> = {
  #   description ? name; exec; environment ? { }; after ? [ ];
  #   wantedBy ? [ "multi-user.target" ]; serviceConfig ? { };
  # }
  units ? { },
}:
let
  lib = pkgs.lib;
  kinds = import ./kinds.nix lib;
  kind' = kinds.check "layer '${name}'" kind;
  units' = units;

  packages' = if builtins.isFunction packages then packages pkgs else packages;

  toValue = v: if builtins.isBool v then lib.boolToString v else toString v;

  renderUnit =
    unitName: svc:
    let
      wantedBy = svc.wantedBy or [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        Restart = "on-failure";
      }
      // (svc.serviceConfig or { })
      // {
        ExecStart = svc.exec;
      };
      env = svc.environment or { };
    in
    ''
      [Unit]
      Description=${svc.description or unitName}
      ${lib.optionalString ((svc.after or [ ]) != [ ]) "After=${lib.concatStringsSep " " svc.after}"}

      [Service]
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "${k}=${toValue v}") serviceConfig)}
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "Environment=\"${k}=${toValue v}\"") env)}

      [Install]
      WantedBy=${lib.concatStringsSep " " wantedBy}
    '';

  unitNames = map (n: "${n}.service") (builtins.attrNames units');

  unitFiles = pkgs.runCommand "ftl-layer-${name}-units" { } ''
    mkdir -p $out/lib/systemd/system
    ${lib.concatStrings (
      lib.mapAttrsToList (n: svc: ''
        cp ${pkgs.writeText "${n}.service" (renderUnit n svc)} $out/lib/systemd/system/${n}.service
        ${lib.concatMapStrings (target: ''
          mkdir -p $out/lib/systemd/system/${target}.wants
          ln -s ../${n}.service $out/lib/systemd/system/${target}.wants/${n}.service
        '') (svc.wantedBy or [ "multi-user.target" ])}
      '') units'
    )}
  '';

  meta = pkgs.writeTextDir "share/ftl-layer/meta.json" (
    builtins.toJSON {
      inherit name;
      kind = kind';
      units = unitNames;
    }
  );
in
assert lib.assertMsg (
  kind' == "units" || units' == { }
) "ftl: layer '${name}' defines units but is not of kind \"units\"";
pkgs.buildEnv {
  name = "ftl-layer-${name}";
  paths = packages' ++ [ meta ] ++ lib.optional (kind' == "units") unitFiles;
  pathsToLink = [ "/" ];
  ignoreCollisions = false;
}
