# Generators: how a set of files is made for a host. ftl's own (the host keys
# every host needs, a dedicated age key) and nixos/generators/<name>.nix, each
# { pkgs }: { description?; runtimeInputs?; files; script; }. What they make
# is `fleet.generators`; as programs they are packages.<sys>.generate-<name>,
# which `fleetl host generate` runs.
ctx:
let
  inherit (ctx)
    lib
    loader
    dir
    pkgsFor
    ;
in
rec {
  generatorFiles = {
    host-keys = ../generators/host-keys.nix;
    age-key = ../generators/age-key.nix;
  }
  // loader.loadTreeIfExists { dir = dir "generators"; };

  # What a generator makes, without a package set.
  generators = builtins.mapAttrs (
    name: file:
    let
      g = import file { pkgs = throw "ftl: generator '${name}' may use pkgs only in runtimeInputs"; };
    in
    {
      inherit (g) files;
      description = g.description or name;
    }
  ) generatorFiles;

  # generate-<name> <dir>: the generator as a program, writing its files into <dir>.
  generatorPrograms =
    system:
    let
      pkgs = pkgsFor system;
    in
    builtins.mapAttrs (
      name: file:
      let
        g = import file { inherit pkgs; };
      in
      pkgs.writeShellApplication {
        name = "generate-${name}";
        runtimeInputs = g.runtimeInputs or [ ];
        text = ''
          out="''${1:?usage: generate-${name} <dir>}"
          HOST="''${HOST:-host}"
          export HOST out
          mkdir -p "$out"
          ${g.script}
        '';
      }
    ) generatorFiles;
}
