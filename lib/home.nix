# mkHome: home/ folder -> home-manager modules, profiles and configurations.
#
#   home/modules/**.nix        shared into every configuration (homeModules)
#   home/profiles/<dir>/*.nix  building blocks; a base lists profile dirs and
#                              includes only their direct .nix files
#   home/profiles/<dir>/nixos.nix
#                              not a home module: the NixOS side that profile
#                              cannot do without (a PAM entry, portals, fonts),
#                              imported into a host that gives a user a
#                              configuration built from the dir (`companions`)
#   home/variants/*.nix        one configuration per base x variant
#
# Configurations are named <base>-<variant> (or <base> without variants) and
# built for every system in `systems`.
{
  src,
  # system -> package set
  pkgsFor,
  lib,
  systems ? [ "x86_64-linux" ],
  # home-manager flake input; without it only modules/profiles are produced.
  homeManager ? null,
  # name -> list of profile dirs (relative to profiles/), e.g.
  # { desktop = [ "terminal" "desktop" ]; }
  bases ? { },
  # directory (relative to src) with one module per variant, or null
  variants ? "variants",
  # extra modules shared into every configuration (e.g. upstream modules)
  sharedModules ? [ ],
  extraSpecialArgs ? { },
  # default home.username / home.homeDirectory for every configuration
  username ? null,
}:
let
  loader = import ./loader.nix;

  homeModules = loader.loadTreeIfExists { dir = src + "/modules"; };
  homeProfiles = loader.loadTreeIfExists { dir = src + "/profiles"; };
  variantFiles =
    if variants == null then { } else loader.loadTreeIfExists { dir = src + "/${variants}"; };

  profileDir =
    dir: lib.attrByPath (lib.splitString "/" dir) (throw "ftl: home: no profile dir '${dir}'") homeProfiles;

  # Direct .nix files of a profile dir ("desktop/light" -> its files only),
  # its nixos.nix aside.
  directFiles =
    dir: builtins.attrValues (lib.filterAttrs (n: v: !builtins.isAttrs v && n != "nixos") (profileDir dir));

  # The NixOS modules the dirs of a base need on the host.
  companionFiles = dir: lib.optional ((profileDir dir) ? nixos) (profileDir dir).nixos;

  mkModule =
    imports:
    { lib, ... }:
    {
      inherit imports;
      home = lib.optionalAttrs (username != null) {
        username = lib.mkDefault username;
        homeDirectory = lib.mkDefault "/home/${username}";
      };
    };

  baseFiles = builtins.mapAttrs (_: dirs: builtins.concatMap directFiles dirs) bases;
  baseCompanions = builtins.mapAttrs (_: dirs: lib.unique (builtins.concatMap companionFiles dirs)) bases;

  # configuration name -> the NixOS modules its base needs
  companions =
    if variantFiles == { } then
      baseCompanions
    else
      builtins.listToAttrs (
        lib.concatLists (
          lib.mapAttrsToList (
            base: files: lib.mapAttrsToList (variant: _: lib.nameValuePair "${base}-${variant}" files) variantFiles
          ) baseCompanions
        )
      );

  # name -> module (also handed to NixOS hosts as `homes`)
  modules =
    if variantFiles == { } then
      builtins.mapAttrs (_: mkModule) baseFiles
    else
      builtins.listToAttrs (
        lib.concatLists (
          lib.mapAttrsToList (
            base: files:
            lib.mapAttrsToList (variant: path: {
              name = "${base}-${variant}";
              value = mkModule (files ++ [ path ]);
            }) variantFiles
          ) baseFiles
        )
      );

  # Upstream modules first, then home/modules (attribute order).
  allSharedModules = sharedModules ++ loader.collectPaths homeModules;

  configurationsFor =
    system:
    if homeManager == null then
      { }
    else
      builtins.mapAttrs (
        _: module:
        homeManager.lib.homeManagerConfiguration {
          pkgs = pkgsFor system;
          modules = allSharedModules ++ [ module ];
          inherit extraSpecialArgs;
        }
      ) modules;

  configurations = lib.genAttrs systems configurationsFor;

  checks = lib.genAttrs systems (
    system:
    lib.mapAttrs' (n: c: lib.nameValuePair "home-${n}" c.activationPackage) configurations.${system}
  );

  manifestEntries = lib.concatMap (
    system:
    map (n: {
      checkName = "home-${n}";
      kind = "home";
      host = null;
      layer = null;
      inherit system;
      importance = "optional";
      configAttr = "legacyPackages.${system}.homeConfigurations.${n}";
    }) (builtins.attrNames configurations.${system})
  ) systems;
in
{
  inherit
    homeModules
    homeProfiles
    modules
    companions
    allSharedModules
    extraSpecialArgs
    configurations
    checks
    manifestEntries
    ;
}
