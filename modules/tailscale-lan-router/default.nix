# tailscale-lan-router — turn a NixOS box into a LAN router with a
# bridge + NAT + Kea DHCP + Blocky ad-blocking DNS (+ optional IPv6 radvd),
# with an optional fix so LAN clients also egress through a Tailscale exit node.
#
# The load-bearing insight lives in the `tailscaleExitNode` option description
# below: when the router itself uses a Tailscale exit node, forwarded LAN
# packets keep their 192.168.x source, fall outside the exit node's WireGuard
# AllowedIPs, and are dropped silently. The fix is to MASQUERADE LAN traffic
# onto tailscale0 (and open the FORWARD path + udp/41641).
#
# Drop-in usage:
#   imports = [ ./tailscale-lan-router ];
#   modules.lan-router = {
#     enable        = true;
#     wanInterface  = "enp1s0";
#     bridge.interfaces = [ "enp2s0" "enp3s0" ];
#     lan.v4 = {
#       address  = "192.168.100.1";
#       subnet   = "192.168.100.0/24";
#       dhcpPool = "192.168.100.100 - 192.168.100.200";
#     };
#     dns.upstreams = [ "1.1.1.1" "8.8.8.8" ];
#     tailscaleExitNode = true;   # only if this router uses an exit node
#   };
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.lan-router;
  bridgeAddr4 = "${cfg.lan.v4.address}/${toString cfg.lan.v4.prefixLength}";
  bridgeAddr6 = lib.optionalString cfg.lan.v6.enable "${cfg.lan.v6.address}/${toString cfg.lan.v6.prefixLength}";

  # networking.firewall.extraCommands/extraStopCommands and
  # networking.nat.extraCommands/extraStopCommands are each asserted =="" by
  # nixpkgs' nftables-based firewall/NAT backends (firewall-nftables.nix,
  # nat-nftables.nix) -- see the two backend flags below. FORWARD needs no
  # nftables-side translation: neither backend filters the forward hook
  # unless `networking.firewall.filterForward` is turned on (nftables-only,
  # off by default and NOT toggled by this module), so forwarded traffic is
  # open-by-default under both backends and the iptables path's explicit
  # FORWARD ACCEPT rules are already redundant with that default. Only the
  # INPUT-side icmpv6 accept (INPUT is filtered by default, unlike FORWARD)
  # and the tailscale0 MASQUERADE need a real nftables-side rule.
  nftFirewall = config.networking.firewall.backend == "nftables";
  nftNat = config.networking.nftables.enable;
  denylistNames = lib.attrNames cfg.dns.blocking.denylists;
in
{
  options.modules.lan-router = {
    enable = lib.mkEnableOption "LAN router with bridge, NAT, DHCP, and DNS";

    bridge = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "brlan";
        description = "Name of the LAN bridge device";
      };
      interfaces = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Physical interfaces to add to the bridge";
        example = [ "enp2s0" ];
      };
    };

    wanInterface = lib.mkOption {
      type = lib.types.str;
      description = "WAN interface for NAT (externalInterface)";
      example = "enp1s0";
    };

    lan.v4 = {
      address = lib.mkOption {
        type = lib.types.str;
        description = "LAN gateway IPv4 address (bare, no prefix)";
        example = "192.168.100.1";
      };
      prefixLength = lib.mkOption {
        type = lib.types.int;
        default = 24;
      };
      subnet = lib.mkOption {
        type = lib.types.str;
        description = "LAN IPv4 subnet in CIDR notation";
        example = "192.168.100.0/24";
      };
      dhcpPool = lib.mkOption {
        type = lib.types.str;
        description = "DHCP pool range for Kea";
        example = "192.168.100.100 - 192.168.100.200";
      };
    };

    lan.v6 = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      address = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "fd00:100::1";
      };
      prefixLength = lib.mkOption {
        type = lib.types.int;
        default = 64;
      };
      subnet = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "fd00:100::/64";
      };
      dhcpPool = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "fd00:100::100 - fd00:100::200";
      };
    };

    dns = {
      upstreams = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Upstream DNS servers for Blocky";
        example = [
          "1.1.1.1"
          "8.8.8.8"
        ];
      };

      blocking = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        denylists = lib.mkOption {
          type = lib.types.attrsOf (lib.types.listOf lib.types.str);
          default = { };
          description = "Named denylists (URLs or inline patterns) for Blocky";
          example = {
            stevenblack = [ "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" ];
          };
        };
      };

      customMappings = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Custom DNS hostname→IP mappings";
        example = {
          "router.lan" = "192.168.100.1";
        };
      };

      httpPort = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = "Blocky HTTP API port (null to disable)";
        example = 4000;
      };
    };

    tailscaleExitNode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable when this router uses a Tailscale exit node so that LAN
        client traffic also exits through the tunnel.

        Tailscale's policy routing (table 52) captures forwarded LAN
        packets and sends them through tailscale0, but the exit node's
        WireGuard AllowedIPs only includes the router's Tailscale IP.
        Packets with source 192.168.x get dropped silently.

        This fix adds MASQUERADE on tailscale0 so LAN traffic is
        source-NATted to the router's Tailscale IP before entering
        the tunnel.  The WAN masquerade remains as fallback when
        Tailscale is down.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
    }
    // lib.optionalAttrs cfg.lan.v6.enable {
      "net.ipv6.conf.all.forwarding" = 1;
    };

    networking = {
      useDHCP = lib.mkDefault false;
      resolvconf.useLocalResolver = true;

      nat = {
        enable = true;
        internalInterfaces = [ cfg.bridge.name ];
        externalInterface = cfg.wanInterface;
      }
      // lib.optionalAttrs (cfg.tailscaleExitNode && !nftNat) {
        extraCommands = ''
          iptables -t nat -C POSTROUTING -s ${cfg.lan.v4.subnet} -o tailscale0 -j MASQUERADE 2>/dev/null \
            || iptables -t nat -A POSTROUTING -s ${cfg.lan.v4.subnet} -o tailscale0 -j MASQUERADE
        '';
        extraStopCommands = ''
          iptables -t nat -D POSTROUTING -s ${cfg.lan.v4.subnet} -o tailscale0 -j MASQUERADE 2>/dev/null || true
        '';
      };

      # networking.nat's nftables backend (nat-nftables.nix) has no
      # extraCommands escape hatch at all (it asserts them =="" ), so the
      # exit-node MASQUERADE gets its own small nftables table instead of
      # piggybacking on `networking.nat`.
      nftables.tables."lan-router-tailscale-nat" = lib.mkIf (cfg.tailscaleExitNode && nftNat) {
        family = "ip";
        content = ''
          chain postrouting {
            type nat hook postrouting priority srcnat + 1;
            ip saddr ${cfg.lan.v4.subnet} oifname "tailscale0" masquerade
          }
        '';
      };

      firewall = {
        trustedInterfaces = [ cfg.bridge.name ];

        extraCommands = lib.optionalString (!nftFirewall) (
          lib.optionalString cfg.lan.v6.enable ''
            ip6tables -C INPUT -p icmpv6 -j ACCEPT 2>/dev/null \
              || ip6tables -A INPUT -p icmpv6 -j ACCEPT
            ip6tables -C FORWARD -p icmpv6 -j ACCEPT 2>/dev/null \
              || ip6tables -A FORWARD -p icmpv6 -j ACCEPT
          ''
          + lib.optionalString cfg.tailscaleExitNode ''
            iptables -C FORWARD -i ${cfg.bridge.name} -o tailscale0 -p udp --dport 41641 -j ACCEPT 2>/dev/null \
              || iptables -A FORWARD -i ${cfg.bridge.name} -o tailscale0 -p udp --dport 41641 -j ACCEPT
            iptables -C FORWARD -i tailscale0 -o ${cfg.bridge.name} -p udp --sport 41641 -j ACCEPT 2>/dev/null \
              || iptables -A FORWARD -i tailscale0 -o ${cfg.bridge.name} -p udp --sport 41641 -j ACCEPT
            iptables -C FORWARD -i ${cfg.bridge.name} -o tailscale0 -j ACCEPT 2>/dev/null \
              || iptables -A FORWARD -i ${cfg.bridge.name} -o tailscale0 -j ACCEPT
            iptables -C FORWARD -i tailscale0 -o ${cfg.bridge.name} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
              || iptables -A FORWARD -i tailscale0 -o ${cfg.bridge.name} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
          ''
        );
        extraStopCommands = lib.optionalString (!nftFirewall) (
          lib.optionalString cfg.lan.v6.enable ''
            ip6tables -D INPUT -p icmpv6 -j ACCEPT 2>/dev/null || true
            ip6tables -D FORWARD -p icmpv6 -j ACCEPT 2>/dev/null || true
          ''
          + lib.optionalString cfg.tailscaleExitNode ''
            iptables -D FORWARD -i ${cfg.bridge.name} -o tailscale0 -p udp --dport 41641 -j ACCEPT 2>/dev/null || true
            iptables -D FORWARD -i tailscale0 -o ${cfg.bridge.name} -p udp --sport 41641 -j ACCEPT 2>/dev/null || true
            iptables -D FORWARD -i ${cfg.bridge.name} -o tailscale0 -j ACCEPT 2>/dev/null || true
            iptables -D FORWARD -i tailscale0 -o ${cfg.bridge.name} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
          ''
        );

        # input-allow is spliced in regardless of filterForward, so this
        # works on the nftables backend with no other config required. There
        # is no FORWARD-side rule to add: neither backend filters the
        # forward hook unless filterForward is on (see the note above), so
        # this module never touches it.
        extraInputRules = lib.optionalString (nftFirewall && cfg.lan.v6.enable) ''
          ip6 nexthdr icmpv6 accept
        '';
      };
    };

    systemd.network = {
      enable = true;
      wait-online.enable = lib.mkDefault false;

      netdevs."${cfg.bridge.name}".netdevConfig = {
        Kind = "bridge";
        Name = cfg.bridge.name;
      };

      networks = lib.mkMerge [
        (lib.listToAttrs (
          lib.imap0 (i: iface: {
            name = "${toString (10 + i)}-lan-${iface}";
            value = {
              matchConfig.Name = iface;
              networkConfig.Bridge = cfg.bridge.name;
              linkConfig.RequiredForOnline = "no";
            };
          }) cfg.bridge.interfaces
        ))

        {
          "20-${cfg.bridge.name}" = {
            matchConfig.Name = cfg.bridge.name;
            address = [ bridgeAddr4 ] ++ lib.optional cfg.lan.v6.enable bridgeAddr6;
            networkConfig = {
              ConfigureWithoutCarrier = true;
            }
            // lib.optionalAttrs cfg.lan.v6.enable {
              IPv6SendRA = false;
            };
            linkConfig = {
              RequiredForOnline = "no";
              ActivationPolicy = "always-up";
            };
          };
        }
      ];
    };

    services.resolved.enable = false;
    services.blocky = {
      enable = true;
      settings = {
        ports = {
          dns = "127.0.0.1:53,${cfg.lan.v4.address}:53";
        }
        // lib.optionalAttrs (cfg.dns.httpPort != null) {
          http = "127.0.0.1:${toString cfg.dns.httpPort},${cfg.lan.v4.address}:${toString cfg.dns.httpPort}";
        };

        upstreams = {
          groups.default = cfg.dns.upstreams;
          timeout = "2s";
        };

        blocking = lib.mkIf cfg.dns.blocking.enable {
          denylists = cfg.dns.blocking.denylists;
          clientGroupsBlock.default = denylistNames;
          blockType = "nxDomain";
          blockTTL = "1m";
          loading = {
            strategy = "fast";
            refreshPeriod = "12h";
            downloads = {
              timeout = "60s";
              attempts = 5;
              cooldown = "10s";
            };
          };
        };

        caching = {
          minTime = "5m";
          maxTime = "30m";
          prefetching = true;
          prefetchThreshold = 5;
          prefetchExpires = "2h";
          cacheTimeNegative = "30m";
        };

        customDNS.mapping = {
          "${cfg.bridge.name}.lan" = cfg.lan.v4.address;
        }
        // cfg.dns.customMappings;

        log = {
          level = "info";
          privacy = true;
        };
      };
    };
    systemd.services.blocky.stopIfChanged = false;

    services.kea.dhcp4 = {
      enable = true;
      settings = {
        interfaces-config.interfaces = [ cfg.bridge.name ];
        lease-database = {
          type = "memfile";
          persist = true;
          name = "/var/lib/kea/dhcp4.leases";
        };
        valid-lifetime = 3600;
        max-valid-lifetime = 43200;
        subnet4 = [
          {
            id = 1;
            subnet = cfg.lan.v4.subnet;
            pools = [ { pool = cfg.lan.v4.dhcpPool; } ];
            option-data = [
              {
                name = "routers";
                data = cfg.lan.v4.address;
              }
              {
                name = "domain-name-servers";
                data = cfg.lan.v4.address;
              }
              {
                name = "domain-name";
                data = "lan";
              }
            ];
          }
        ];
      };
    };

    services.kea.dhcp6 = lib.mkIf cfg.lan.v6.enable {
      enable = true;
      settings = {
        interfaces-config.interfaces = [ cfg.bridge.name ];
        lease-database = {
          type = "memfile";
          persist = true;
          name = "/var/lib/kea/dhcp6.leases";
        };
        valid-lifetime = 3600;
        max-valid-lifetime = 43200;
        subnet6 = [
          {
            id = 1;
            subnet = cfg.lan.v6.subnet;
            pools = [ { pool = cfg.lan.v6.dhcpPool; } ];
            option-data = [
              {
                name = "dns-servers";
                data = cfg.lan.v6.address;
              }
            ];
          }
        ];
      };
    };

    services.radvd = lib.mkIf cfg.lan.v6.enable {
      enable = true;
      config = ''
        interface ${cfg.bridge.name} {
          AdvSendAdvert on;
          AdvManagedFlag on;
          AdvOtherConfigFlag on;
          MinRtrAdvInterval 30;
          MaxRtrAdvInterval 100;

          prefix ${cfg.lan.v6.subnet} {
            AdvOnLink on;
            AdvAutonomous on;
            AdvRouterAddr on;
          };

          RDNSS ${cfg.lan.v6.address} {
          };
        };
      '';
    };

  };
}
