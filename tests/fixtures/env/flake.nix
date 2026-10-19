{
  description = "ftl test fixture environment (offline-buildable toy attrs)";

  # The only input: a plain directory whose content steers which fixture
  # attrs succeed, so the VM test can make the pipeline's `nix flake update`
  # pick up a "bad" bump without any network access.
  inputs.dep = {
    url = "path:/var/lib/fixture-dep";
    flake = false;
  };

  outputs =
    { self, dep }:
    let
      system = "x86_64-linux";
      content = builtins.readFile "${dep}/data";
      stamp = builtins.hashString "sha256" content;
      broken = marker: builtins.match ".*${marker}.*" content != null;

      mk =
        name: fail:
        derivation {
          inherit name system;
          builder = "/bin/sh";
          args = [
            "-c"
            (if fail then "echo deliberately failing ${name}; exit 1" else "echo ok ${name} ${stamp} > $out")
          ];
        };

      entry = checkName: kind: host: layer: importance: {
        inherit
          kind
          host
          layer
          system
          importance
          ;
        configAttr = if kind == "layer" then "nixosLayers.${system}.${layer}" else "nixosConfigurations.${host}";
        flakeAttr = "checks.${system}.${checkName}";
      };
    in
    {
      checks.${system} = {
        nixos-alpha = mk "nixos-alpha" false;
        nixos-beta = mk "nixos-beta" (broken "break-beta");
        nixos-layer-gaming = mk "nixos-layer-gaming" (broken "break-gaming");
      };

      fleet.manifest = {
        name = "fixture";
        repo = null;
        version = 1;
        attrs.${system} = {
          nixos-alpha = entry "nixos-alpha" "nixos" "alpha" null "required";
          nixos-beta = entry "nixos-beta" "nixos" "beta" null "required";
          nixos-layer-gaming = entry "nixos-layer-gaming" "layer" null "gaming" "optional";
        };
      };
    };
}
