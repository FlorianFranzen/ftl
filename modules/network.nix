# fleet.network: a host's uplink from the `network` block of its host.nix,
# with systemd-networkd.
#
#   network = {
#     mac = "…";  or  interface = "…";      # how to find the uplink
#     ipv4 = { address; prefixLength; gateway; };
#     ipv6 = { address; prefixLength; gateway?; delegatedPrefix?; };
#     nameservers = [ … ];
#   };
#
# Without an IPv6 gateway the default route comes from router advertisements.
# With `delegatedPrefix` the host asks for that prefix over DHCPv6 and uses
# `address` from it as a /128, with no SLAAC address next to it: one global
# address, the one in DNS, so it is also the source of what the host sends.
# Temporary (privacy) addresses are off: other hosts' allow lists, DNS and PTR
# records know the stable ones. The network is called 10-wan, so a host can
# add drop-ins to it. Where the initrd brings up networking (fleet.access's
# initrd unlock, or a host's own), it gets the same uplink, IPv4 only.
#
# On under mkNixos for every host with a `network` block; hosts without one
# keep their own networking.
{
  config,
  lib,
  options,
  ...
}@args:

let
  cfg = config.fleet.network;
  fleet = args.fleet or null;
  net = cfg.uplink;
  v4 = net.ipv4;
  v6 = net.ipv6 or null;

  delegated = v6 != null && v6 ? delegatedPrefix;
  match = if net ? mac then { MACAddress = net.mac; } else { Name = net.interface; };

  ipv4 = {
    address = [ "${v4.address}/${toString v4.prefixLength}" ];
    routes = [
      {
        Gateway = v4.gateway;
        GatewayOnLink = true;
      }
    ];
  };
in
{
  options.fleet.network = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.uplink != null;
      defaultText = lib.literalExpression "fleet.network.uplink != null";
      description = "Configure the uplink from `uplink` (the host's `network` block).";
    };

    uplink = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      default = if fleet != null then fleet.self.network or null else null;
      defaultText = lib.literalExpression "fleet.self.network (the host's `network` block), or null";
      description = ''
        `{ mac | interface; ipv4 = { address; prefixLength; gateway; };
        ipv6 = { address; prefixLength; gateway?; delegatedPrefix?; };
        nameservers; }`, see the head of modules/network.nix.
      '';
    };

    ownNames = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        The host's own names resolve to its public addresses instead of
        127.0.0.2 (NixOS's default, IPv4 only), so a service name that points
        at this host takes the same path from here as from elsewhere.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = net ? mac || net ? interface;
        message = "fleet.network: the `network` block needs `mac` or `interface` to find the uplink";
      }
      {
        assertion =
          net ? ipv4
          && lib.all (a: net.ipv4 ? ${a}) [
            "address"
            "prefixLength"
            "gateway"
          ];
        message = "fleet.network: the `network` block needs ipv4 = { address; prefixLength; gateway; }";
      }
      {
        assertion =
          v6 == null
          || lib.all (
            a:
            builtins.elem a [
              "address"
              "prefixLength"
              "gateway"
              "delegatedPrefix"
            ]
          ) (builtins.attrNames v6);
        message = "fleet.network: ipv6 takes address, prefixLength, gateway and delegatedPrefix";
      }
    ];

    networking.useNetworkd = true;
    networking.useDHCP = lib.mkDefault false;
    networking.tempAddresses = lib.mkDefault "disabled";
    networking.nameservers = net.nameservers or [ ];

    networking.hosts = lib.mkIf cfg.ownNames (
      let
        names = lib.unique [
          config.networking.fqdnOrHostName
          config.networking.hostName
        ];
      in
      {
        "127.0.0.2" = lib.mkForce [ ];
        ${v4.address} = names;
      }
      // lib.optionalAttrs (v6 != null) { ${v6.address} = names; }
    );

    systemd.network.networks."10-wan" = {
      matchConfig = match;

      address =
        ipv4.address
        ++
          lib.optional (v6 != null)
            "${v6.address}/${toString (if delegated then 128 else v6.prefixLength)}";

      routes =
        ipv4.routes
        ++ lib.optional (v6 != null && v6 ? gateway) {
          Gateway = v6.gateway;
          GatewayOnLink = true;
        };

      networkConfig = {
        IPv6AcceptRA = v6 == null || !(v6 ? gateway);
        DHCP = if delegated then "ipv6" else "no";
      };

      ipv6AcceptRAConfig = {
        UseDNS = false;
        UseAutonomousPrefix = !delegated;
      };

      dhcpV6Config = lib.mkIf delegated {
        PrefixDelegationHint = v6.delegatedPrefix;
        WithoutRA = "solicit";
        UseAddress = false;
        UseDNS = false;
      };

      linkConfig.RequiredForOnline = "routable";
    };

    # the same uplink in the initrd, wherever it brings up networking
    boot.initrd.systemd.network =
      # (nixpkgs without the scripted initrd removed the switch: always systemd)
      lib.mkIf
        (
          config.boot.initrd.network.enable
          && (
            (options.boot.initrd.systemd.enable.visible or true) == false || config.boot.initrd.systemd.enable
          )
        )
        {
          enable = true;
          networks."10-wan" = ipv4 // {
            matchConfig = match;
          };
        };
  };
}
