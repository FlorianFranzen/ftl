# fleet.smartcard: smartcard access bound to the registered readers.
#
# On as soon as a reader is registered for the host (mkFlake's `smartcard`
# for every host, `smartcard` in host.nix for one; set by mkNixos), and then:
#
#   - pcscd runs, and ignores every USB device but the registered readers.
#     pcscd has no allow-list, so a udev rule marks every USB device
#     PCSCLITE_IGNORE=1 and the registered ones back to 0 (pcsc-lite reads the
#     property from the reader's usb_device and skips it when it is exactly
#     "1"). Another program's card, a test key or a stray token is invisible
#     to everything that goes through pcscd. Only the smartcard (CCID)
#     interface is affected; FIDO2, U2F and OTP over hidraw are not.
#   - scdaemon goes through pcscd (`disable-ccid`) instead of claiming the USB
#     device itself, so gpg obeys the same filter and leaves the card to pcscd.
#   - attended (a person touches the key): yubikey-touch-detector notifies the
#     desktop session while a key waits for a touch.
#   - headless (nobody does): the key, provisioned without touch, is used
#     through nix-piv's piv-agent (nix-piv.nixosModules.agent, imported through
#     nixos.sharedModules). Local applications reach it through its shared
#     socket, open to the agent's group (ssh-agent itself serves only its own
#     user and root); a pipeline on this host (fleet.builder) joins the group
#     and uses that socket.
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.fleet.smartcard;
  vocab = import ../lib/smartcard.nix { inherit lib; };

  hasTouchDetector = options ? programs && options.programs ? yubikey-touch-detector;
  hasAgent = options ? services && options.services ? piv-agent;
  # nix-piv versions with a socket for a group
  hasAgentGroup = hasAgent && options.services.piv-agent ? accessGroup;
  agent = config.services.piv-agent;
  agentOn = hasAgent && agent.enable;
  shared = hasAgentGroup && agent.accessGroup != null;
  # fleet.builder, when its module is imported too (it is under mkNixos)
  hasBuilder = options ? fleet && options.fleet ? builder;
  builder = config.fleet.builder;
  # the agent's own socket serves its user and root, the shared one the group
  builderSocket = if shared && agent.user != builder.user then agent.sharedSocket else agent.socket;

  usbId = lib.types.strMatching vocab.usbIdPattern;
  # serial and port end up between double quotes in a udev rule
  udevValue = lib.types.strMatching vocab.udevValuePattern;

  readerRule =
    r:
    lib.concatStringsSep ", " (
      [ ''ATTR{idVendor}=="${r.vendor}"'' ]
      ++ lib.optional (r.product != null) ''ATTR{idProduct}=="${r.product}"''
      ++ lib.optional (r.serial != null) ''ATTR{serial}=="${r.serial}"''
      ++ lib.optional (r.port != null) ''KERNEL=="${r.port}"''
      ++ [ ''ENV{PCSCLITE_IGNORE}="0"'' ]
    );
in
{
  imports = [ ./agents.nix ];

  options.fleet.smartcard = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.readers != { };
      defaultText = lib.literalExpression "fleet.smartcard.readers != { }";
      description = ''
        Smartcard access through pcscd, bound to `readers`. Registering a
        reader is what turns it on.
      '';
    };

    presence = lib.mkOption {
      type = lib.types.enum vocab.presences;
      default = "attended";
      description = ''
        `attended`: a person is at the host and touches the key when asked.
        `headless`: nobody is; the key is provisioned without touch and used
        through nix-piv's agent.
      '';
    };

    readers = lib.mkOption {
      default = { };
      description = ''
        The readers pcscd may use; every other USB device is ignored. A
        reader matches on every attribute that is set.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            vendor = lib.mkOption {
              type = usbId;
              example = "1050";
              description = "USB vendor id (lsusb), lower case.";
            };
            product = lib.mkOption {
              type = lib.types.nullOr usbId;
              default = null;
              example = "0407";
              description = "USB product id (lsusb), lower case.";
            };
            serial = lib.mkOption {
              type = lib.types.nullOr udevValue;
              default = null;
              description = ''
                USB serial number (`udevadm info -a`, ATTR{serial}). YubiKeys
                report none unless configured to; use `port` for those.
              '';
            };
            port = lib.mkOption {
              type = lib.types.nullOr udevValue;
              default = null;
              example = "1-4.2";
              description = "USB port, the kernel name of the device (`/sys/bus/usb/devices/<port>`).";
            };
            description = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
          };
        }
      );
    };

    scdaemon = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          A system-wide scdaemon.conf with `disable-ccid`: gpg reaches cards
          through pcscd, and so through the reader filter, instead of claiming
          the USB device and taking it from pcscd.
        '';
      };
      shared = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          `pcsc-shared`: scdaemon no longer holds every reader exclusively for
          as long as it runs, so PIV tools work next to gpg; gpg then fails once
          or twice after a PIV command before it works again. Worth it when both
          are used every day; otherwise stay exclusive and run
          `gpgconf --kill scdaemon` before PIV work.
        '';
      };
    };

    touchDetector = lib.mkOption {
      type = lib.types.bool;
      default = cfg.presence == "attended";
      defaultText = lib.literalExpression ''fleet.smartcard.presence == "attended"'';
      description = ''
        yubikey-touch-detector in graphical sessions: a notification while a
        key waits for a touch (gpg and FIDO; PIV through PKCS#11 is not seen).
      '';
    };

    agent = lib.mkOption {
      type = lib.types.bool;
      default = cfg.presence == "headless";
      defaultText = lib.literalExpression ''fleet.smartcard.presence == "headless"'';
      description = ''
        Enable nix-piv's piv-agent (when its module is imported): an ssh-agent
        holding the card's keys, unlocked at boot from a sealed PIN, with a
        shared socket for the agent's group (local applications join that
        group). A fleet.builder on this host joins it and uses it as
        `sshAuthSock`.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.readers != { };
            message = "fleet.smartcard is enabled without a registered reader: register one in host.nix (smartcard.readers) or mkFlake's smartcard argument";
          }
        ];

        services.pcscd.enable = true;
        environment.systemPackages = [ pkgs.opensc ];

        services.udev.extraRules = ''
          # fleet.smartcard: pcscd uses the registered readers only
          ACTION=="remove", GOTO="fleet_smartcard_end"
          SUBSYSTEM!="usb", GOTO="fleet_smartcard_end"
          ENV{DEVTYPE}!="usb_device", GOTO="fleet_smartcard_end"
          ENV{PCSCLITE_IGNORE}="1"
          ${lib.concatMapStringsSep "\n" readerRule (builtins.attrValues cfg.readers)}
          LABEL="fleet_smartcard_end"
        '';

        environment.etc."gnupg/scdaemon.conf" = lib.mkIf cfg.scdaemon.enable {
          text = lib.mkDefault (
            ''
              # fleet.smartcard: through pcscd, which only offers the registered readers
              disable-ccid
            ''
            + lib.optionalString cfg.scdaemon.shared ''
              pcsc-shared
            ''
          );
        };

        warnings = lib.optional (cfg.agent && !hasAgent) ''
          fleet.smartcard: host is headless, but nix-piv's agent module is not imported;
          add nix-piv.nixosModules.agent to mkFlake's nixos.sharedModules (or set
          fleet.smartcard.agent = false).
        '';

        fleet.agents.sections.smartcard = {
          order = 10;
          text = ''
            ## Smartcard readers

            This host is **${cfg.presence}**. pcscd uses only these readers and
            ignores every other USB device: ${vocab.readersText cfg.readers}. gpg goes through pcscd${lib.optionalString cfg.scdaemon.shared ", sharing the readers (`pcsc-shared`)"}.
          ''
          + lib.optionalString agentOn (''

            The card's keys are in nix-piv's agent: `SSH_AUTH_SOCK=${agent.socket}`
            for `${agent.user}` and root${lib.optionalString shared ", `SSH_AUTH_SOCK=${agent.sharedSocket}` for members of the group `${agent.accessGroup}`"} (`ssh-add -l` lists the keys). It is unlocked by `piv-agent-unlock.service`
            from the sealed PIN in `${agent.pinCredential}`.
          '');
        };
      }

      (lib.optionalAttrs hasTouchDetector {
        programs.yubikey-touch-detector.enable = lib.mkIf cfg.touchDetector (lib.mkDefault true);
      })

      (lib.optionalAttrs hasAgent (
        lib.mkIf cfg.agent (
          lib.mkMerge [
            { services.piv-agent.enable = lib.mkDefault true; }

            (lib.optionalAttrs hasAgentGroup {
              services.piv-agent.accessGroup = lib.mkDefault agent.group;
            })

            # the pipeline pushes, signs commits and reaches remote builders
            # with the card
            # (optionalAttrs, not mkIf: without the builder module its options
            # do not exist at all)
            (lib.optionalAttrs hasBuilder (
              lib.mkIf builder.enable (
                {
                  fleet.builder.sshAuthSock = lib.mkDefault builderSocket;
                }
                // lib.optionalAttrs hasAgentGroup {
                  users.users.${builder.user}.extraGroups = lib.mkIf (shared && agent.user != builder.user) [
                    agent.accessGroup
                  ];
                }
              )
            ))
          ]
        )
      ))
    ]
  );
}
