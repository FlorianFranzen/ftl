# ftl.builder: the update/build/promote pipeline host.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ftl.builder;
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
in
{
  imports = [ ./meta.nix ];

  options.ftl.builder = {
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
      default = "/var/lib/ftl";
      description = "Pipeline state (mirrors, worktrees, manifests).";
    };
    statusDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/ftl-status";
      description = "Published status JSON (served by ftl.cache).";
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
        description = "SSH private key path (ssh) or GnuPG key id (openpgp, e.g. a smartcard-backed key).";
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

    deployKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "SSH key used to push refs to the environment repos.";
    };

    cache = {
      dir = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/data/cache";
        description = "file:// binary cache populated by the pipeline (null = no cache push).";
      };
      secretKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "NAR signing secret (nix key generate-secret).";
      };
      publicKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Matching public key; when set, this host substitutes from its own cache.";
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
        message = "ftl.builder.signing.key must be set when signing is enabled";
      }
      {
        assertion = cfg.cache.dir == null || cfg.cache.secretKeyFile != null;
        message = "ftl.builder.cache.secretKeyFile must be set when cache.dir is set (unsigned caches are not served)";
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
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.statusDir} 0755 ${cfg.user} ${cfg.group} -"
    ]
    ++ lib.optional (cfg.cache.dir != null) "d ${cfg.cache.dir} 0755 ${cfg.user} ${cfg.group} -"
    ++ lib.optional (cfg.metricsDir != null) "d ${cfg.metricsDir} 0755 ${cfg.user} ${cfg.group} -";

    # Let the builder host substitute from its own cache, so aggressive GC of
    # the local store costs nothing.
    nix.settings = lib.mkIf (cfg.cache.dir != null && cfg.cache.publicKey != null) {
      extra-substituters = [ "file://${cfg.cache.dir}?priority=20" ];
      extra-trusted-public-keys = [ cfg.cache.publicKey ];
    };

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
            // lib.optionalAttrs (cfg.cache.secretKeyFile != null) {
              FTL_CACHE_SECRET = cfg.cache.secretKeyFile;
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
              ExecStart = lib.getExe scripts.ftl-pipeline;
              TimeoutStartSec = "12h";
              Nice = 10;
              IOSchedulingClass = "best-effort";
              IOSchedulingPriority = 7;
            };
          };
        }
      ) laneServices
    );

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
