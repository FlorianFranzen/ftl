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
  # { lib } -> { gitUrl }: the git URL of a repo given as a git URL or flake reference
  repo = import ./repo.nix;
  # { lib } -> { fleet; host; rules; pushCommand; }: the AGENTS.md text
  agents = import ./agents.nix;
  mkLayer = import ./layer.nix;
  mkManifest = import ./manifest.nix;
}
