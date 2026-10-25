# Generators: how a set of files is made. ftl's own (the host keys every host
# needs, a dedicated age key) and nixos/generators/<name>.nix, each
# { pkgs }: { description?; scope?; inputs?; runtimeInputs?; files; script; }.
#
# A generator's scope is `host` (run per host, listed in its host.nix; the
# files land next to host.nix and in the host's stores) or `fleet` (run once
# for the fleet; the files land in nixos/ and in nixos/secrets.yaml or
# nixos/identity.yaml). `inputs` are files of other generators it reads
# (`<generator>/<file>`, in `$in` when it runs): a certificate signed by the
# fleet's CA, a key derived from the host's. A fleet generator reads fleet
# files only.
#
# What they make is `fleet.generators`; as programs they are
# packages.<sys>.generate-<name>, which `fleetl host generate` and `fleetl
# fleet generate` run. The fleet's public files (nixos/<name>.pub) are
# `fleet.keys.<name>`.
ctx:
let
  inherit (ctx)
    lib
    loader
    src
    dir
    pkgsFor
    ;

  scopes = [
    "host"
    "fleet"
  ];

  generatorFiles = {
    host-keys = ../generators/host-keys.nix;
    age-key = ../generators/age-key.nix;
    fleet-ca = ../generators/fleet-ca.nix;
    host-tls = ../generators/host-tls.nix;
    wireguard = ../generators/wireguard.nix;
  }
  // loader.loadTreeIfExists { dir = dir "generators"; };

  raw = builtins.mapAttrs (
    name: file:
    import file { pkgs = throw "ftl: generator '${name}' may use pkgs only in runtimeInputs"; }
  ) generatorFiles;

  generatorOf = input: builtins.head (lib.splitString "/" input);
  fileOf = input: lib.concatStringsSep "/" (builtins.tail (lib.splitString "/" input));

  # The generators an input chain reaches from a generator; a generator in
  # its own chain is a cycle.
  reach =
    name: seen:
    assert lib.assertMsg (
      !(builtins.elem name seen)
    ) "ftl: generator '${name}' is an input of itself (through ${toString seen})";
    lib.unique (
      lib.concatMap (i: [ (generatorOf i) ] ++ reach (generatorOf i) (seen ++ [ name ])) (
        raw.${name}.inputs or [ ]
      )
    );

  normalize =
    name: g:
    let
      scope = g.scope or "host";
      inputs = g.inputs or [ ];
      unknown = lib.filter (i: !(raw ? ${generatorOf i})) inputs;
      undeclared = lib.filter (i: !(raw.${generatorOf i}.files or { } ? ${fileOf i})) (
        lib.filter (i: raw ? ${generatorOf i}) inputs
      );
      hostInputs = lib.filter (i: (raw.${generatorOf i}.scope or "host") == "host") inputs;
    in
    assert lib.assertMsg (builtins.elem scope scopes)
      "ftl: generator '${name}' has invalid scope '${scope}'";
    assert lib.assertMsg (
      unknown == [ ]
    ) "ftl: generator '${name}' has inputs of undefined generators: ${toString unknown}";
    assert lib.assertMsg (
      undeclared == [ ]
    ) "ftl: generator '${name}' has inputs its generators do not make: ${toString undeclared}";
    assert lib.assertMsg (
      scope == "host" || hostInputs == [ ]
    ) "ftl: fleet generator '${name}' reads host files: ${toString hostInputs}";
    assert builtins.isList (reach name [ ]);
    {
      inherit (g) files;
      inherit scope inputs;
      description = g.description or name;
    };
in
rec {
  inherit generatorFiles;

  # What a generator makes and needs, without a package set.
  generators = builtins.mapAttrs normalize raw;

  # The fleet's public files: every nixos/<name>.pub (`fleet.keys`).
  fleetKeys =
    if src == null then
      { }
    else
      lib.concatMapAttrs (
        n: t:
        let
          value = if t == "regular" && lib.hasSuffix ".pub" n then ctx.readKey (dir n) else null;
        in
        lib.optionalAttrs (value != null) {
          ${lib.removeSuffix ".pub" n} = value;
        }
      ) (builtins.readDir src);

  # generate-<name> <out> [<in>]: the generator as a program, writing its
  # files into <out>, reading its inputs under <in>/<generator>/<file>.
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
          out="''${1:?usage: generate-${name} <out> [<in>]}"
          in="''${2:-}"
          HOST="''${HOST:-host}"
          # the host's metadata as JSON (fleetl passes fleet.hosts.<h>)
          if [ -z "''${HOST_JSON:-}" ]; then
            HOST_JSON="$(mktemp)"
            echo '{}' >"$HOST_JSON"
          fi
          export HOST HOST_JSON out in
          mkdir -p "$out"
          ${g.script}
        '';
      }
    ) generatorFiles;
}
