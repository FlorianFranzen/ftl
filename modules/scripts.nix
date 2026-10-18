# Packaged ftl scripts. writeShellApplication runs shellcheck over each
# script at build time, so the shell sources double as checked code.
{ pkgs }:
rec {
  ftl-cache-retention = pkgs.writeShellApplication {
    name = "ftl-cache-retention";
    runtimeInputs = with pkgs; [
      jq
      gawk
      gnused
      gnugrep
      findutils
      coreutils
    ];
    text = builtins.readFile ../scripts/ftl-cache-retention.sh;
  };

  ftl-pipeline = pkgs.writeShellApplication {
    name = "ftl-pipeline";
    runtimeInputs = with pkgs; [
      git
      jq
      curl
      openssh
      gnupg
      nix-fast-build
      coreutils
      ftl-cache-retention
    ];
    text = builtins.readFile ../scripts/ftl-pipeline.sh;
  };

  ftl-layers = pkgs.writeShellApplication {
    name = "ftl-layers";
    runtimeInputs = with pkgs; [
      git
      jq
      curl
      openssh
      gnupg
      gnugrep
      gnused
      coreutils
      inetutils # hostname
      systemd
    ];
    text = builtins.readFile ../scripts/ftl-layers.sh;
  };

  # The admin's command line: fleetl, and ftl as its alias.
  fleetl =
    let
      script = pkgs.writeShellApplication {
        name = "fleetl";
        runtimeInputs = with pkgs; [
          nix
          git
          jq
          yq-go
          sops
          ssh-to-age
          age
          openssh
          gnupg
          nixos-anywhere
          coreutils
          diffutils
          gnused
          gawk
        ];
        text = builtins.readFile ../scripts/fleetl.sh;
      };
    in
    pkgs.symlinkJoin {
      name = "fleetl";
      paths = [ script ];
      postBuild = "ln -s fleetl $out/bin/ftl";
      meta.mainProgram = "fleetl";
    };

  ftl-status = pkgs.writeShellApplication {
    name = "ftl-status";
    runtimeInputs = with pkgs; [
      git
      jq
      curl
      gawk
      coreutils
    ];
    text = builtins.readFile ../scripts/ftl-status.sh;
  };
}
