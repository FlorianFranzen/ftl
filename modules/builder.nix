# fleet.builder: the update/build/promote pipeline host.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.builder;
  rootDir = config.fleet.rootDir;
  scripts = import ./scripts.nix { inherit pkgs; };

  laneServices = lib.concatMap (
    repoName:
    let
      repo = cfg.repos.${repoName};
    in
    map (laneName: {
      inherit repoName laneName repo;
      lane = repo.lanes.${laneName};
      unitName = "ftl-pipeline-${repoName}-${laneName}";
    }) (builtins.attrNames repo.lanes)
  ) (builtins.attrNames cfg.repos);

  enabledRemotes = lib.filterAttrs (_: rb: rb.enable) cfg.remoteBuilders;

  # flock wrapper: a lane that finds its repo busy exits 75 (EX_TEMPFAIL)
  # with a log line instead of trampling the other lane's state.
  lockedPipeline = pkgs.writeShellScript "ftl-pipeline-locked" ''
    lock="$1"
    ${pkgs.util-linux}/bin/flock -n -E 75 "$lock" ${lib.getExe scripts.ftl-pipeline}
    rc=$?
    if [ "$rc" = 75 ]; then
      echo "ftl-pipeline[$FTL_REPO_NAME/$FTL_LANE]: another lane of $FTL_REPO_NAME is running; skipping this run" >&2
    fi
    exit "$rc"
  '';
in
{
  imports = [
    ./meta.nix
    ./dirs.nix
    ./agents.nix
  ];

  options.fleet.builder = {
    enable = lib.mkEnableOption "the ftl update pipeline";

    user = lib.mkOption {
      type = lib.types.str;
      default = "ftl";
      description = "User the pipeline runs as.";
    };
    group = lib.mkOption {
      type = lib.types.str;
      default = "ftl";
      description = "Group the pipeline runs as.";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "${rootDir}/state";
      defaultText = lib.literalExpression ''"''${config.fleet.rootDir}/state"'';
      description = "Private pipeline state (mirrors, worktrees, manifests).";
    };
    statusDir = lib.mkOption {
      type = lib.types.path;
      default = "${rootDir}/status";
      defaultText = lib.literalExpression ''"''${config.fleet.rootDir}/status"'';
      description = "Published status JSON (served by fleet.cache).";
    };
    metricsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "node_exporter textfile collector directory for pipeline metrics.";
    };

    promote = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Fast-forward the deployed branch (and push broken/* refs) after building.";
    };

    evalWorkers = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "nix-eval-jobs worker count (memory bound).";
    };

    ntfy.url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://ntfy.example.org/ftl";
      description = "ntfy topic URL for state-transition notifications.";
    };

    signing = {
      format = lib.mkOption {
        type = lib.types.enum [
          "none"
          "ssh"
          "openpgp"
        ];
        default = "none";
        description = "How the pipeline signs its lock-bump commits.";
      };
      key = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          ssh: path of an SSH private key, or `key::<public key>` for a key held by the agent
          at `sshAuthSock` (e.g. on a smartcard). openpgp: GnuPG key id (e.g. a
          smartcard-backed key).
        '';
      };
      name = lib.mkOption {
        type = lib.types.str;
        default = "ftl pipeline";
        description = "git author name for pipeline commits.";
      };
      email = lib.mkOption {
        type = lib.types.str;
        default = "ftl@localhost";
        description = "git author email for pipeline commits.";
      };
      gnupgHome = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "GNUPGHOME holding the builder's (smartcard) signing key setup (openpgp format).";
      };
    };

    verify = {
      mode = lib.mkOption {
        type = lib.types.enum [
          "none"
          "ssh"
          "gpg"
        ];
        default = "none";
        description = ''
          Signature verification of the tip of each repo's branch before the
          pipeline builds on it. Without it, anything that lands on the branch
          is wrapped in a builder-signed commit and promoted, so host-side
          signature checks only prove write access to the forge. The allowed
          signers must include the builder's own signing key, since the
          previous promotion is a builder commit.
        '';
      };
      allowedSignersFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "OpenSSH allowed_signers file (ssh mode).";
      };
      gpgHome = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "GNUPGHOME whose keyring holds exactly the trusted public keys (gpg mode).";
      };
    };

    knownHostsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        known_hosts file pinning the environment repos' SSH host keys. Without
        it ssh consults `programs.ssh.knownHosts` (/etc/ssh/ssh_known_hosts)
        and the pipeline user's own known_hosts; unknown hosts are refused.
      '';
    };

    deployKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        SSH key used to push refs to the environment repos (readable by the ftl user).
        Leave it null to authenticate through `sshAuthSock` instead.
      '';
    };

    sshAuthSock = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/piv-agent/agent.sock";
      description = ''
        ssh-agent socket (`SSH_AUTH_SOCK`) for keys that must not live in files, e.g. on a
        smartcard. The pipeline uses it to push (when `deployKeyFile` is null) and to sign
        commits (`signing.format = "ssh"` with `signing.key = "key::<public key>"`), and
        nix-daemon uses it for remote builders without `sshKey`. The agent must be
        reachable by the ftl user; root (nix-daemon) can always connect.
      '';
    };

    cache = {
      dir = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = "${rootDir}/cache";
        defaultText = lib.literalExpression ''"''${config.fleet.rootDir}/cache"'';
        description = "file:// binary cache populated by the pipeline (null = no cache push).";
      };
      secretKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/var/lib/ftl/keys/cache.secret";
        description = ''
          NAR signing secret (create it with `nix key generate-secret`). It is
          handed to nix-daemon via `secret-key-files`, which signs every
          locally built path at build time, so the pipeline user never reads
          it: keep it `0400 root:root`. The file must exist before this
          configuration is activated; nix-daemon fails every local build
          while it is missing. When null, the pipeline builds but pushes
          nothing to the cache (unsigned paths are never published).
        '';
      };
      publicKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Matching public key; when set, this host substitutes from its own cache.";
      };
      signer.command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = lib.literalExpression "config.services.piv-cache-signer.requestCommand";
        description = ''
          Command that signs what the pipeline pushed, for keys nix-daemon cannot hold (e.g.
          on a smartcard). After each build the pipeline writes the closure of every green
          path, one store path per line, to a queue file and runs
          `<command> <cache dir> <queue file>` as the ftl user; the command must add `Sig:`
          lines to the narinfos in the cache (`nix store sign --store file://… --stdin`
          does, as does nix-piv's cache signer). It may run alongside `secretKeyFile`
          (paths then carry both signatures). A failure is reported, not fatal: unsigned
          narinfos are refused by clients that require this key.
        '';
      };
    };

    repos = lib.mkOption {
      default = { };
      description = "Environment repositories driven by this builder.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            url = lib.mkOption {
              type = lib.types.str;
              description = "git URL (ssh/https/file) of the environment repo.";
            };
            branch = lib.mkOption {
              type = lib.types.str;
              default = "main";
              description = "Branch the pipeline bases candidates on.";
            };
            systems = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "x86_64-linux" ];
              description = "Systems this builder builds for this repo.";
            };
            keepGenerations = lib.mkOption {
              type = lib.types.ints.positive;
              default = 5;
              description = "Promoted generations per attr retained in the cache.";
            };
            extraBuildArgs = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Extra arguments appended to nix-fast-build.";
            };
            lanes = lib.mkOption {
              default = {
                default = { };
              };
              description = "Update lanes: which inputs are bumped together, and when.";
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    inputs = lib.mkOption {
                      type = lib.types.listOf lib.types.str;
                      default = [ ];
                      description = "Flake inputs this lane updates (empty = all).";
                    };
                    schedule = lib.mkOption {
                      type = lib.types.str;
                      default = "daily";
                      description = "systemd OnCalendar expression.";
                    };
                  };
                }
              );
            };
          };
        }
      );
    };

    remoteBuilders = lib.mkOption {
      default = { };
      description = "Remote build machines, each behind an enable toggle.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            enable = lib.mkEnableOption "this remote builder";
            hostName = lib.mkOption { type = lib.types.str; };
            sshUser = lib.mkOption {
              type = lib.types.str;
              default = "ftl-build";
            };
            sshKey = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "SSH key nix-daemon uses for this builder; null = the agent at `sshAuthSock`.";
            };
            systems = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "x86_64-linux" ];
            };
            maxJobs = lib.mkOption {
              type = lib.types.ints.positive;
              default = 4;
            };
            speedFactor = lib.mkOption {
              type = lib.types.ints.positive;
              default = 2;
            };
            supportedFeatures = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [
                "big-parallel"
                "kvm"
                "nixos-test"
              ];
            };
            publicHostKey = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.signing.format == "none" || cfg.signing.key != null;
        message = "fleet.builder.signing.key must be set when signing is enabled";
      }
      {
        assertion = cfg.verify.mode != "ssh" || cfg.verify.allowedSignersFile != null;
        message = "fleet.builder.verify.allowedSignersFile must be set for verify.mode = \"ssh\"";
      }
      {
        assertion = cfg.verify.mode != "gpg" || cfg.verify.gpgHome != null;
        message = "fleet.builder.verify.gpgHome must be set for verify.mode = \"gpg\"";
      }
      {
        assertion = lib.all (rb: rb.publicHostKey != null) (builtins.attrValues enabledRemotes);
        message = "fleet.builder.remoteBuilders.<name>.publicHostKey must be set: outputs of an unauthenticated remote would be signed and promoted";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
      useDefaultShell = true;
    };
    users.groups.${cfg.group} = { };

    systemd.tmpfiles.rules = [
      "d ${rootDir} 0755 root root -"
      "d ${rootDir}/keys 0750 root ${cfg.group} -"
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.statusDir} 0755 ${cfg.user} ${cfg.group} -"
    ]
    ++ lib.optional (cfg.cache.dir != null) "d ${cfg.cache.dir} 0755 ${cfg.user} ${cfg.group} -"
    ++ lib.optional (cfg.metricsDir != null) "d ${cfg.metricsDir} 0755 ${cfg.user} ${cfg.group} -";

    # Let the builder host substitute from its own cache, so aggressive GC of
    # the local store costs nothing.
    nix.settings = lib.mkMerge [
      (lib.mkIf (cfg.cache.dir != null && cfg.cache.publicKey != null) {
        extra-substituters = [ "file://${cfg.cache.dir}?priority=20" ];
        extra-trusted-public-keys = [ cfg.cache.publicKey ];
      })
      # nix-daemon (root) signs at build time; the key never enters the
      # pipeline user's reach, where the flake it evaluates could read it.
      (lib.mkIf (cfg.cache.secretKeyFile != null) {
        secret-key-files = [ (toString cfg.cache.secretKeyFile) ];
      })
    ];

    nix.distributedBuilds = lib.mkIf (enabledRemotes != { }) true;

    nix.buildMachines = lib.mapAttrsToList (_: rb: {
      inherit (rb)
        hostName
        sshUser
        systems
        maxJobs
        speedFactor
        supportedFeatures
        publicHostKey
        ;
      sshKey = toString rb.sshKey;
      protocol = "ssh-ng";
    }) enabledRemotes;

    systemd.services = builtins.listToAttrs (
      map (
        { repoName, laneName, repo, lane, unitName }:
        {
          name = unitName;
          value = {
            description = "ftl pipeline: ${repoName} (${laneName} lane)";
            path = [
              config.nix.package
              pkgs.git
              pkgs.openssh
            ];
            environment = {
              FTL_REPO_NAME = repoName;
              FTL_REPO_URL = repo.url;
              FTL_BRANCH = repo.branch;
              FTL_LANE = laneName;
              FTL_LANE_INPUTS = lib.concatStringsSep " " lane.inputs;
              FTL_STATE_DIR = cfg.stateDir;
              FTL_STATUS_DIR = cfg.statusDir;
              FTL_SYSTEMS = lib.concatStringsSep " " repo.systems;
              FTL_PROMOTE = if cfg.promote then "1" else "0";
              FTL_KEEP_GENERATIONS = toString repo.keepGenerations;
              FTL_SIGN_FORMAT = cfg.signing.format;
              FTL_GIT_NAME = cfg.signing.name;
              FTL_GIT_EMAIL = cfg.signing.email;
              FTL_EVAL_WORKERS = toString cfg.evalWorkers;
              NIX_CONFIG = "experimental-features = nix-command flakes";
              HOME = cfg.stateDir;
            }
            // lib.optionalAttrs (cfg.signing.key != null) { FTL_SIGN_KEY = cfg.signing.key; }
            // lib.optionalAttrs (cfg.signing.gnupgHome != null) { GNUPGHOME = cfg.signing.gnupgHome; }
            // lib.optionalAttrs (cfg.deployKeyFile != null) { FTL_DEPLOY_KEY = cfg.deployKeyFile; }
            // lib.optionalAttrs (cfg.cache.dir != null) { FTL_CACHE_DIR = cfg.cache.dir; }
            // lib.optionalAttrs (cfg.cache.secretKeyFile != null || cfg.cache.signer.command != null) {
              FTL_CACHE_SIGNED = "1";
            }
            // lib.optionalAttrs (cfg.cache.secretKeyFile != null) { FTL_CACHE_DAEMON_SIGNED = "1"; }
            // lib.optionalAttrs (cfg.cache.signer.command != null) {
              FTL_CACHE_SIGN_COMMAND = cfg.cache.signer.command;
            }
            // lib.optionalAttrs (cfg.sshAuthSock != null) { SSH_AUTH_SOCK = cfg.sshAuthSock; }
            // lib.optionalAttrs (cfg.verify.mode != "none") { FTL_VERIFY_MODE = cfg.verify.mode; }
            // lib.optionalAttrs (cfg.verify.allowedSignersFile != null) {
              FTL_ALLOWED_SIGNERS = toString cfg.verify.allowedSignersFile;
            }
            // lib.optionalAttrs (cfg.verify.gpgHome != null) {
              FTL_VERIFY_GPG_HOME = toString cfg.verify.gpgHome;
            }
            // lib.optionalAttrs (cfg.knownHostsFile != null) {
              FTL_KNOWN_HOSTS = toString cfg.knownHostsFile;
            }
            // lib.optionalAttrs (cfg.metricsDir != null) {
              FTL_METRICS_FILE = "${cfg.metricsDir}/ftl-${repoName}.prom";
            }
            // lib.optionalAttrs (cfg.ntfy.url != null) { FTL_NTFY_URL = cfg.ntfy.url; }
            // lib.optionalAttrs (repo.extraBuildArgs != "") {
              FTL_EXTRA_BUILD_ARGS = repo.extraBuildArgs;
            };
            serviceConfig = {
              Type = "oneshot";
              User = cfg.user;
              Group = cfg.group;
              # Lanes of one repo share the mirror, manifest, status and
              # promotion log: never let two of them run at once.
              ExecStart = "${lockedPipeline} ${cfg.stateDir}/${repoName}.lock";
              TimeoutStartSec = "12h";
              Nice = 10;
              IOSchedulingClass = "best-effort";
              IOSchedulingPriority = 7;

              # Sandboxing. Nix goes through the daemon socket, git and ssh
              # through the network; the only writable trees are ftl's own.
              NoNewPrivileges = true;
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              ReadWritePaths = [
                cfg.stateDir
                cfg.statusDir
              ]
              ++ lib.optional (cfg.cache.dir != null) cfg.cache.dir
              ++ lib.optional (cfg.metricsDir != null) cfg.metricsDir
              ++ lib.optional (cfg.signing.gnupgHome != null) cfg.signing.gnupgHome;
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectKernelLogs = true;
              ProtectControlGroups = true;
              ProtectClock = true;
              ProtectHostname = true;
              RestrictSUIDSGID = true;
              RestrictRealtime = true;
              LockPersonality = true;
              SystemCallArchitectures = "native";
            };
          };
        }
      ) laneServices
    )
    # remote builders without sshKey authenticate through the agent
    // lib.optionalAttrs (cfg.sshAuthSock != null) {
      nix-daemon.environment.SSH_AUTH_SOCK = cfg.sshAuthSock;
    };

    fleet.agents.sections.builder = {
      order = 30;
      text = ''
        ## Build pipeline

        This host builds the fleet: ${
          lib.concatMapStringsSep ", " (l: "`${l.unitName}`") laneServices
        } run as `${cfg.user}` on their timers (`systemctl start <unit>` for a run
        now, `journalctl -u <unit>` for its log). The pipeline's state in
        `${cfg.stateDir}` is its own: never edit it, and never run the pipeline's
        git or nix commands there by hand. What it built last is in
        `${cfg.statusDir}`.${
          lib.optionalString (cfg.cache.dir != null)
            " The binary cache is `${cfg.cache.dir}`; only the pipeline writes to it."
        } `${rootDir}/keys` holds the pipeline's keys: never read, copy or print them.
      '';
    };

    systemd.timers = builtins.listToAttrs (
      map (
        { unitName, lane, ... }:
        {
          name = unitName;
          value = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = lane.schedule;
              Persistent = true;
              RandomizedDelaySec = "30min";
            };
          };
        }
      ) laneServices
    );

    environment.systemPackages = [
      scripts.ftl-pipeline
      scripts.ftl-cache-retention
    ];
  };
}
