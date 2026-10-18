let
  loader = import ./loader.nix;
in
{
  inherit (loader) loadTree collectPaths;
  mkFlake = import ./flake.nix;
  mkPackages = import ./packages.nix;
  mkNixos = import ./nixos.nix;
  mkHome = import ./home.nix;
  mkStatic = import ./static.nix;
  mkUsers = import ./users.nix;
  mkDeploy = import ./deploy.nix;
  mkLayer = import ./layer.nix;
  mkManifest = import ./manifest.nix;
}
