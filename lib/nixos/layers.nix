# Layers: nixos/layers/<name>.nix ({ kind; packages; units; }) with explicit
# ones merged over them, built with mkLayer for every system a host that is
# not ignored installs them on.
ctx:
let
  inherit (ctx)
    lib
    loader
    dir
    layers
    pkgsFor
    kinds
    ;
in
rec {
  layers' = builtins.mapAttrs (_: import) (loader.loadTreeIfExists { dir = dir "layers"; }) // layers;

  layerKind = layerName: kinds.check "layer '${layerName}'" (layers'.${layerName}.kind or "packages");

  # Systems each layer is needed for.
  layerSystems = builtins.mapAttrs (
    layerName: _:
    lib.unique (
      lib.mapAttrsToList (_: h: h.system) (
        lib.filterAttrs (_: h: h.importance != "ignored" && builtins.elem layerName h.layers) ctx.hosts'
      )
    )
  ) layers';

  nixosLayers = lib.genAttrs (lib.unique (lib.flatten (builtins.attrValues layerSystems))) (
    system:
    builtins.mapAttrs (
      layerName: def:
      import ../layer.nix {
        pkgs = pkgsFor system;
        name = layerName;
        kind = layerKind layerName;
        packages = def.packages or [ ];
        units = def.units or { };
      }
    ) (lib.filterAttrs (layerName: _: builtins.elem system layerSystems.${layerName}) layers')
  );
}
