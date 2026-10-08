# Minimal stand-in for the home-manager flake, so ftl's tests need no extra
# input. Configurations are evaluated with a freeform `home` option; the NixOS
# module evaluates every user's home module the same way and exposes the
# result as home-manager.evaluated.<user> for assertions.
{ lib }:
let
  homeOptions =
    { lib, ... }:
    {
      options.home = lib.mkOption {
        type = lib.types.lazyAttrsOf lib.types.anything;
        default = { };
      };
    };

  evalHome =
    {
      pkgs,
      modules,
      extraSpecialArgs ? { },
    }:
    (lib.evalModules {
      modules = modules ++ [ homeOptions ];
      specialArgs = extraSpecialArgs // {
        inherit pkgs;
      };
    }).config;
in
{
  lib.homeManagerConfiguration =
    args:
    let
      config = evalHome args;
    in
    {
      inherit config;
      activationPackage = args.pkgs.writeText "home-manager-activation" (
        builtins.toJSON {
          username = config.home.username or null;
          files = builtins.attrNames (config.home.file or { });
        }
      );
    };

  nixosModules.home-manager =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.home-manager;
    in
    {
      options.home-manager = {
        backupFileExtension = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        useGlobalPkgs = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
        useUserPackages = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
        sharedModules = lib.mkOption {
          type = lib.types.listOf lib.types.raw;
          default = [ ];
        };
        extraSpecialArgs = lib.mkOption {
          type = lib.types.attrs;
          default = { };
        };
        users = lib.mkOption {
          type = lib.types.attrsOf lib.types.deferredModule;
          default = { };
        };
        evaluated = lib.mkOption {
          type = lib.types.raw;
          readOnly = true;
          default = builtins.mapAttrs (
            _: module:
            evalHome {
              inherit pkgs;
              modules = cfg.sharedModules ++ [ module ];
              inherit (cfg) extraSpecialArgs;
            }
          ) cfg.users;
        };
      };
    };
}
