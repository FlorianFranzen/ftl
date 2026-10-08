# mkPackages: pkgs/ folder -> overlay, package sets and flake packages.
#
#   pkgs/<name>/package.nix  top-level package <name> (final.callPackage),
#                            patches/scripts/test.nix live next to it
#   pkgs/overlay.nix         optional overlay applied after the packages
#                            (overrides, kernel modules, anything else); may
#                            use any other subdirectory of pkgs/ freely
#   pkgs/config.nix          optional nixpkgs config ({ lib }: { ... } or attrs)
{
  src ? null,
  nixpkgs,
  systems ? [
    "x86_64-linux"
    "aarch64-linux"
  ],
  # Overlays applied before the local one.
  overlays ? [ ],
  # nixpkgs config; defaults to pkgs/config.nix (or { }).
  config ? null,
}:
let
  lib = nixpkgs.lib;

  has = file: src != null && builtins.pathExists (src + "/${file}");
  entries = if src != null && builtins.pathExists src then builtins.readDir src else { };

  packageNames = builtins.filter (n: entries.${n} == "directory" && has "${n}/package.nix") (
    builtins.attrNames entries
  );

  byName = final: _prev: lib.genAttrs packageNames (n: final.callPackage (src + "/${n}/package.nix") { });
  overlayFile = if has "overlay.nix" then import (src + "/overlay.nix") else (_: _: { });
  overlay = lib.composeManyExtensions [
    byName
    overlayFile
  ];

  config' =
    if config != null then
      config
    else if has "config.nix" then
      (
        let
          c = import (src + "/config.nix");
        in
        if builtins.isFunction c then c { inherit lib; } else c
      )
    else
      { };

  allOverlays = overlays ++ [ overlay ];

  mkPkgs =
    system:
    import nixpkgs {
      inherit system;
      overlays = allOverlays;
      config = config';
    };
  pkgs = lib.genAttrs systems mkPkgs;
  pkgsFor = system: pkgs.${system} or (mkPkgs system);

  available =
    p: system:
    let
      # only derivations (helper functions stay in legacyPackages)
      r = builtins.tryEval (lib.isDerivation p && lib.meta.availableOn pkgs.${system}.stdenv.hostPlatform p);
    in
    r.success && r.value;

  packages = lib.genAttrs systems (
    system:
    lib.filterAttrs (_: p: available p system) (lib.genAttrs packageNames (n: pkgs.${system}.${n}))
  );
in
{
  inherit
    overlay
    packageNames
    packages
    pkgs
    pkgsFor
    ;
  overlays = allOverlays;
  config = config';
}
