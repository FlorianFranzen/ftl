# Smartcard readers: registration (fleet-wide and per host), the module they
# turn on, and the hand-over to nix-piv's agent on headless hosts (its options
# stubbed here; nix-piv's own tests run it on a card).
{
  lib,
  ftl,
  nixpkgs,
  check,
  ...
}:
let
  # services.piv-agent as nix-piv declares it
  pivAgentStub =
    { lib, ... }:
    {
      options.services.piv-agent = {
        enable = lib.mkEnableOption "the stub";
        user = lib.mkOption { default = "piv-agent"; };
        group = lib.mkOption { default = "piv-agent"; };
        socket = lib.mkOption { default = "/run/piv-agent/agent.sock"; };
        sharedSocket = lib.mkOption { default = "/run/piv-agent-shared/agent.sock"; };
        pinCredential = lib.mkOption { default = "/var/lib/piv-agent/pin.cred"; };
        accessGroup = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
      };
    };

  mk =
    {
      sharedModules ? [ pivAgentStub ],
      hosts ? { },
      smartcard ? {
        readers.yk = {
          vendor = "1050";
          product = "0407";
          description = "the admin's YubiKey";
        };
      },
    }:
    ftl.lib.mkNixos {
      inherit nixpkgs sharedModules smartcard;
      name = "sc";
      hosts = {
        # the fleet's reader, attended by default
        desk = { };
        # its own reader only, nobody at it, a pipeline on it
        build = {
          smartcard = {
            presence = "headless";
            fleetReaders = false;
            readers.card = {
              vendor = "1050";
              port = "1-4";
            };
          };
          modules = [ { fleet.builder.enable = true; } ];
        };
        # no smartcards at all
        plain.smartcard = null;
        other.smartcard.fleetReaders = false;
      }
      // hosts;
    };

  f = mk { };
  cfg = host: f.nixosConfigurations.${host}.config;
  fails = args: !(builtins.tryEval (builtins.deepSeq (mk args).fleet.hosts true)).success;
  failsHost = spec: fails { hosts.bad.smartcard = spec; };
in
check "unit-smartcard" (
  lib.runTests {
    testRegistration = {
      expr = builtins.mapAttrs (_: h: h.smartcard) f.fleet.hosts;
      expected = {
        desk = {
          presence = "attended";
          readers.yk = {
            vendor = "1050";
            product = "0407";
            serial = null;
            port = null;
            description = "the admin's YubiKey";
          };
        };
        build = {
          presence = "headless";
          readers.card = {
            vendor = "1050";
            product = null;
            serial = null;
            port = "1-4";
            description = null;
          };
        };
        plain = null;
        other = null;
      };
    };

    # registering a reader is what turns the module on
    testActivation = {
      expr = builtins.mapAttrs (h: _: {
        inherit ((cfg h).fleet.smartcard) enable;
        pcscd = (cfg h).services.pcscd.enable;
      }) f.fleet.hosts;
      expected = {
        desk = {
          enable = true;
          pcscd = true;
        };
        build = {
          enable = true;
          pcscd = true;
        };
        plain = {
          enable = false;
          pcscd = false;
        };
        other = {
          enable = false;
          pcscd = false;
        };
      };
    };

    # every USB device ignored by pcscd, the registered readers let back in
    testUdevFilter = {
      expr = {
        desk = lib.filter (l: lib.hasInfix "PCSCLITE_IGNORE" l) (
          lib.splitString "\n" (cfg "desk").services.udev.extraRules
        );
        build = lib.hasInfix ''ATTR{idVendor}=="1050", KERNEL=="1-4", ENV{PCSCLITE_IGNORE}="0"'' (cfg "build")
        .services.udev.extraRules;
      };
      expected = {
        desk = [
          ''ENV{PCSCLITE_IGNORE}="1"''
          ''ATTR{idVendor}=="1050", ATTR{idProduct}=="0407", ENV{PCSCLITE_IGNORE}="0"''
        ];
        build = true;
      };
    };

    testScdaemon = {
      expr = (cfg "desk").environment.etc."gnupg/scdaemon.conf".text;
      expected = ''
        # fleet.smartcard: through pcscd, which only offers the registered readers
        disable-ccid
      '';
    };

    testScdaemonShared = {
      expr = lib.hasInfix "pcsc-shared" (
        (mk {
          hosts.desk.modules = [ { fleet.smartcard.scdaemon.shared = true; } ];
        }).nixosConfigurations.desk.config.environment.etc."gnupg/scdaemon.conf".text
      );
      expected = true;
    };

    # attended: notifications; headless: nix-piv's agent, open to its group,
    # which the pipeline joins and uses
    testPresence = {
      expr = {
        deskTouch = (cfg "desk").programs.yubikey-touch-detector.enable;
        deskAgent = (cfg "desk").services.piv-agent.enable;
        buildTouch = (cfg "build").programs.yubikey-touch-detector.enable;
        buildAgent = {
          inherit ((cfg "build").services.piv-agent) enable accessGroup;
        };
        sshAuthSock = (cfg "build").fleet.builder.sshAuthSock;
        ftlGroups = (cfg "build").users.users.ftl.extraGroups;
      };
      expected = {
        deskTouch = true;
        deskAgent = false;
        buildTouch = false;
        buildAgent = {
          enable = true;
          accessGroup = "piv-agent";
        };
        # the pipeline is not the agent's user: the group's socket
        sshAuthSock = "/run/piv-agent-shared/agent.sock";
        ftlGroups = [ "piv-agent" ];
      };
    };

    # without nix-piv's module a headless host says what is missing
    testHeadlessWithoutAgent = {
      expr = lib.any (lib.hasInfix "nix-piv.nixosModules.agent") (
        (mk { sharedModules = [ ]; }).nixosConfigurations.build.config.warnings
      );
      expected = true;
    };

    testAgentsSection = {
      expr = {
        desk = lib.hasInfix "This host is **attended**" (cfg "desk").fleet.agents.text;
        build = lib.hasInfix "`SSH_AUTH_SOCK=/run/piv-agent-shared/agent.sock` for members of the group `piv-agent`" (cfg "build")
        .fleet.agents.text;
      };
      expected = {
        desk = true;
        build = true;
      };
    };

    # imported on its own (no builder module): no option it does not declare
    testStandalone = {
      expr =
        let
          c =
            (nixpkgs.lib.nixosSystem {
              modules = [
                ftl.nixosModules.smartcard
                pivAgentStub
                {
                  nixpkgs.hostPlatform = "x86_64-linux";
                  fleet.smartcard = {
                    presence = "headless";
                    readers.card.vendor = "1050";
                  };
                }
              ];
            }).config;
        in
        {
          agent = c.services.piv-agent.enable;
          pcscd = c.services.pcscd.enable;
          section = lib.hasInfix "This host is **headless**" c.fleet.agents.sections.smartcard.text;
        };
      expected = {
        agent = true;
        pcscd = true;
        section = true;
      };
    };

    testBadVendor = {
      expr = failsHost { readers.x.vendor = "1050X"; };
      expected = true;
    };
    testUpperCase = {
      expr = failsHost { readers.x.vendor = "ABCD"; };
      expected = true;
    };
    testMissingVendor = {
      expr = failsHost { readers.x.product = "0407"; };
      expected = true;
    };
    testUnknownReaderAttr = {
      expr = failsHost {
        readers.x = {
          vendor = "1050";
          name = "x";
        };
      };
      expected = true;
    };
    testQuoteInSerial = {
      expr = failsHost {
        readers.x = {
          vendor = "1050";
          serial = ''a"b'';
        };
      };
      expected = true;
    };
    testBadPresence = {
      expr = failsHost { presence = "sometimes"; };
      expected = true;
    };
    testUnknownAttr = {
      expr = failsHost { reader = { }; };
      expected = true;
    };
    # fleetReaders is a host's choice; at fleet level it would go unnoticed
    testUnknownFleetAttr = {
      expr = fails {
        smartcard = {
          fleetReaders = false;
          readers.yk.vendor = "1050";
        };
      };
      expected = true;
    };
    testBadFleetReader = {
      expr = fails { smartcard.readers.x.vendor = "nope"; };
      expected = true;
    };
  }
)
