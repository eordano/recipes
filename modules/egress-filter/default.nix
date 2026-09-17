{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.services.egressFilter;

  ipv6Enabled = config.networking.enableIPv6;

  iptables = "${pkgs.iptables}/bin/iptables";
  ip6tables = "${pkgs.iptables}/bin/ip6tables";
  ipset = "${pkgs.ipset}/bin/ipset";
  dig = "${pkgs.dnsutils}/bin/dig";
  grep = "${pkgs.gnugrep}/bin/grep";
  sort = "${pkgs.coreutils}/bin/sort";
  paste = "${pkgs.coreutils}/bin/paste";

  nft = config.networking.firewall.backend == "nftables";
  nftBin = "${pkgs.nftables}/bin/nft";
  nftTable = "egress-filter";

  interfaceOptions =
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          description = "The name of the network interface";
        };

        enable = mkEnableOption "Egress filtering for this interface";

        mode = mkOption {
          type = types.enum [
            "resolve"
            "dnsmasq"
          ];
          default = "resolve";
          description = ''
            Strategy for determining allowed IPs:
            - resolve: Periodically resolve domains and update ipsets (simple, but may miss IP changes)
            - dnsmasq: Intercept DNS queries via dnsmasq and add IPs in real-time (more robust)
          '';
        };

        domains = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [
            "example.com"
            "cdn.example.org"
          ];
          description = ''
            List of domain names to allow outgoing connections to.
            These will be resolved to IP addresses and added to an allowlist.
          '';
        };

        allowedIPs = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [
            "8.8.8.8"
            "1.1.1.1/32"
            "203.0.113.0/24"
            "2001:db8::/32"
          ];
          description = ''
            Static IP addresses or CIDR ranges to allow, beyond the resolved domains.
            Supports both IPv4 and IPv6. IPv6 addresses are automatically detected
            and added to the appropriate ipset.
          '';
        };

        allowedIPv4 = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [
            "8.8.8.8"
            "203.0.113.0/24"
          ];
          description = ''
            Static IPv4 addresses or CIDR ranges to allow.
          '';
        };

        allowedIPv6 = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [
            "2001:db8::/32"
            "2606:4700:4700::1111"
          ];
          description = ''
            Static IPv6 addresses or CIDR ranges to allow.
          '';
        };

        allowPrivateNetworks = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether to allow traffic to private/local networks (RFC1918, loopback,
            link-local). The exact ranges are controlled by `privateNetworksV4`
            and `privateNetworksV6`.

            Security note: the default (`true`) passes through the *entire*
            configured private range regardless of the domain allowlist. A guest
            you meant to confine to a few domains can still reach the whole LAN,
            the host's internal/admin services, the router, and any other machine
            on those ranges. When confining an untrusted guest, set this to
            `false` -- or narrow `privateNetworksV4`/`privateNetworksV6` to just
            the bridge subnet and gateway the guest legitimately needs.
          '';
        };

        privateNetworksV4 = mkOption {
          type = types.listOf types.str;
          default = [
            "127.0.0.0/8"
            "10.0.0.0/8"
            "172.16.0.0/12"
            "192.168.0.0/16"
            "169.254.0.0/16"
          ];
          description = ''
            IPv4 ranges treated as "private" and passed through when
            `allowPrivateNetworks` is enabled. Defaults to loopback, the three
            RFC1918 blocks, and link-local. Add the RFC6598 shared-address-space
            block here if your deployment routes it (e.g. a CGNAT or overlay-VPN
            range that guests must reach).
          '';
        };

        privateNetworksV6 = mkOption {
          type = types.listOf types.str;
          default = [
            "::1/128"
            "fe80::/10"
            "fc00::/7"
            "fd00::/8"
          ];
          description = ''
            IPv6 ranges treated as "private" and passed through when
            `allowPrivateNetworks` is enabled. Defaults to loopback, link-local,
            and unique-local.
          '';
        };

        allowDNS = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether to allow DNS queries (UDP/TCP port 53) to any destination.
            In dnsmasq mode, this is automatically restricted to the local dnsmasq instance.
          '';
        };

        dnsServers = mkOption {
          type = types.listOf types.str;
          default = [
            "1.1.1.1"
            "8.8.8.8"
          ];
          description = ''
            Upstream DNS servers to use for resolving domains.
            In resolve mode: used by dig for periodic resolution.
            In dnsmasq mode: used as upstream servers for dnsmasq.
          '';
        };

        dnsmasq = {
          listenAddress = mkOption {
            type = types.str;
            default = "";
            example = "192.168.100.1";
            description = ''
              IP address for dnsmasq to listen on. Should be the gateway IP of
              the bridge (the address guests use as their resolver). Required in
              dnsmasq mode: if left empty, dnsmasq binds nothing usable and the
              DNS-redirect DNAT points at a bare port, so the interceptor never
              answers.
            '';
          };

          port = mkOption {
            type = types.port;
            default = 53;
            description = "Port for dnsmasq to listen on.";
          };

          redirectDNS = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Whether to redirect all DNS traffic from the interface to the local dnsmasq.
              This ensures guests cannot bypass the DNS interception.
            '';
          };

          cacheSize = mkOption {
            type = types.int;
            default = 1000;
            description = "DNS cache size for dnsmasq.";
          };

          extraConfig = mkOption {
            type = types.lines;
            default = "";
            description = "Extra dnsmasq configuration lines.";
          };
        };
      };
    };

  ipsetName = iface: "egress_allow_${iface}";
  ipsetName6 = iface: "egress_allow6_${iface}";

  mkDnsmasqIpsetConfig =
    name: interface:
    let
      ipset4 = ipsetName name;
      ipset6 = ipsetName6 name;
      ipsetSpec = if ipv6Enabled then "${ipset4},${ipset6}" else ipset4;
    in
    concatMapStringsSep "\n" (domain: "ipset=/${domain}/${ipsetSpec}") interface.domains;

  mkDnsmasqNftsetConfig =
    name: interface:
    let
      spec4 = "4#inet#${nftTable}#${ipsetName name}";
      spec6 = "6#inet#${nftTable}#${ipsetName6 name}";
      spec = if ipv6Enabled then "${spec4},${spec6}" else spec4;
    in
    concatMapStringsSep "\n" (domain: "nftset=/${domain}/${spec}") interface.domains;

  mkDnsmasqConfig =
    name: interface:
    pkgs.writeText "dnsmasq-egress-${name}.conf" ''
      no-resolv

      ${concatMapStringsSep "\n" (server: "server=${server}") interface.dnsServers}

      listen-address=${interface.dnsmasq.listenAddress}
      port=${toString interface.dnsmasq.port}
      bind-interfaces

      cache-size=${toString interface.dnsmasq.cacheSize}


      ${if nft then mkDnsmasqNftsetConfig name interface else mkDnsmasqIpsetConfig name interface}

      ${interface.dnsmasq.extraConfig}
    '';

  mkResolveScript =
    name: interface:
    pkgs.writeShellScript "egress-resolve-${name}" ''
      set -euo pipefail

      IPSET4="${ipsetName name}"
      IPSET6="${ipsetName6 name}"
      TMPFILE=$(mktemp)
      TMPFILE6=$(mktemp)

      ${ipset} create -exist "$IPSET4" hash:net family inet hashsize 1024 maxelem 65536
      ${optionalString ipv6Enabled ''
        ${ipset} create -exist "$IPSET6" hash:net family inet6 hashsize 1024 maxelem 65536
      ''}

      echo "Resolving domains for ${name}..."

      ${concatMapStringsSep "\n" (ip: ''
        echo "${ip}" >> "$TMPFILE"
      '') interface.allowedIPv4}

      ${optionalString ipv6Enabled (
        concatMapStringsSep "\n" (ip: ''
          echo "${ip}" >> "$TMPFILE6"
        '') interface.allowedIPv6
      )}

      ${concatMapStringsSep "\n" (ip: ''
        if echo "${ip}" | ${grep} -qE ':'; then
          ${optionalString ipv6Enabled ''echo "${ip}" >> "$TMPFILE6"''}
        else
          echo "${ip}" >> "$TMPFILE"
        fi
      '') interface.allowedIPs}

      ${concatMapStringsSep "\n" (domain: ''
        echo "Resolving ${domain}..."
        ${dig} +short ${domain} A @${head interface.dnsServers} 2>/dev/null | ${grep} -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >> "$TMPFILE" || true
        ${optionalString ipv6Enabled ''
          ${dig} +short ${domain} AAAA @${head interface.dnsServers} 2>/dev/null | ${grep} -E '^[0-9a-fA-F:]+$' >> "$TMPFILE6" || true
        ''}
        for cname in $(${dig} +short ${domain} CNAME @${head interface.dnsServers} 2>/dev/null || true); do
          ${dig} +short "$cname" A @${head interface.dnsServers} 2>/dev/null | ${grep} -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >> "$TMPFILE" || true
          ${optionalString ipv6Enabled ''
            ${dig} +short "$cname" AAAA @${head interface.dnsServers} 2>/dev/null | ${grep} -E '^[0-9a-fA-F:]+$' >> "$TMPFILE6" || true
          ''}
        done
      '') interface.domains}

      # Rebuild the allowlist in a temp set and atomically swap it in, so the
      # live FORWARD chain never matches a half-built set.
      RESTORE_FILE=$(mktemp)
      SWAP_SET="egress_tmp_${name}"
      SWAP_SET6="egress_tmp6_${name}"

      echo "create $SWAP_SET hash:net family inet hashsize 1024 maxelem 65536" >> "$RESTORE_FILE"
      ${sort} -u "$TMPFILE" | while read -r ip; do
        [ -n "$ip" ] && echo "add $SWAP_SET $ip" >> "$RESTORE_FILE"
      done

      ${optionalString ipv6Enabled ''
        echo "create $SWAP_SET6 hash:net family inet6 hashsize 1024 maxelem 65536" >> "$RESTORE_FILE"
        ${sort} -u "$TMPFILE6" | while read -r ip; do
          [ -n "$ip" ] && echo "add $SWAP_SET6 $ip" >> "$RESTORE_FILE"
        done
      ''}

      ${ipset} restore -! < "$RESTORE_FILE"
      ${ipset} swap "$SWAP_SET" "$IPSET4" 2>/dev/null || ${ipset} rename "$SWAP_SET" "$IPSET4"
      ${ipset} destroy "$SWAP_SET" 2>/dev/null || true

      ${optionalString ipv6Enabled ''
        ${ipset} swap "$SWAP_SET6" "$IPSET6" 2>/dev/null || ${ipset} rename "$SWAP_SET6" "$IPSET6"
        ${ipset} destroy "$SWAP_SET6" 2>/dev/null || true
      ''}

      rm -f "$TMPFILE" "$TMPFILE6" "$RESTORE_FILE"

      echo "Egress filter for ${name} updated with $(${ipset} list "$IPSET4" 2>/dev/null | ${grep} -c '^[0-9]' || echo 0) IPv4 entries"
      ${optionalString ipv6Enabled ''
        echo "Egress filter for ${name} updated with $(${ipset} list "$IPSET6" 2>/dev/null | ${grep} -c '^[0-9a-fA-F]' || echo 0) IPv6 entries"
      ''}
    '';

  mkStaticIpsScript =
    name: interface:
    pkgs.writeShellScript "egress-static-ips-${name}" ''
      set -euo pipefail

      IPSET4="${ipsetName name}"
      IPSET6="${ipsetName6 name}"

      echo "Adding static IPs for ${name}..."

      ${concatMapStringsSep "\n" (ip: ''
        ${ipset} add -exist "$IPSET4" "${ip}"
      '') interface.allowedIPv4}

      ${optionalString ipv6Enabled (
        concatMapStringsSep "\n" (ip: ''
          ${ipset} add -exist "$IPSET6" "${ip}"
        '') interface.allowedIPv6
      )}

      ${concatMapStringsSep "\n" (ip: ''
        if echo "${ip}" | ${grep} -qE ':'; then
          ${optionalString ipv6Enabled ''${ipset} add -exist "$IPSET6" "${ip}"''}
        else
          ${ipset} add -exist "$IPSET4" "${ip}"
        fi
      '') interface.allowedIPs}

      echo "Static IPs added for ${name}"
    '';

  generateIptablesRules =
    name: interface:
    let
      chainName = "EGRESS_FILTER_${name}";
      inputInterfaceFlag = "-i ${name}";
      listenAddr = interface.dnsmasq.listenAddress;
      dnsPort = interface.dnsmasq.port;
    in
    optionalString interface.enable ''
      ${iptables} -N ${chainName} 2>/dev/null || ${iptables} -F ${chainName}

      ${iptables} -A ${chainName} -m state --state ESTABLISHED,RELATED -j ACCEPT

      ${
        if interface.mode == "dnsmasq" && interface.dnsmasq.redirectDNS then
          ''
            ${iptables} -t nat -D PREROUTING ${inputInterfaceFlag} -p udp --dport 53 -j DNAT --to-destination ${listenAddr}:${toString dnsPort} 2>/dev/null || true
            ${iptables} -t nat -D PREROUTING ${inputInterfaceFlag} -p tcp --dport 53 -j DNAT --to-destination ${listenAddr}:${toString dnsPort} 2>/dev/null || true
            ${iptables} -t nat -I PREROUTING 1 ${inputInterfaceFlag} -p udp --dport 53 -j DNAT --to-destination ${listenAddr}:${toString dnsPort}
            ${iptables} -t nat -I PREROUTING 1 ${inputInterfaceFlag} -p tcp --dport 53 -j DNAT --to-destination ${listenAddr}:${toString dnsPort}
            ${iptables} -A ${chainName} -p udp -d ${listenAddr} --dport ${toString dnsPort} -j ACCEPT
            ${iptables} -A ${chainName} -p tcp -d ${listenAddr} --dport ${toString dnsPort} -j ACCEPT
          ''
        else
          optionalString interface.allowDNS ''
            ${iptables} -A ${chainName} -p udp --dport 53 -j ACCEPT
            ${iptables} -A ${chainName} -p tcp --dport 53 -j ACCEPT
          ''
      }

      ${optionalString interface.allowPrivateNetworks (
        concatMapStringsSep "\n" (
          net: "${iptables} -A ${chainName} -d ${net} -j ACCEPT"
        ) interface.privateNetworksV4
      )}

      ${iptables} -A ${chainName} -m set --match-set ${ipsetName name} dst -j ACCEPT

      ${iptables} -A ${chainName} -j DROP

      ${iptables} -D FORWARD ${inputInterfaceFlag} -j ${chainName} 2>/dev/null || true
      ${iptables} -I FORWARD 1 ${inputInterfaceFlag} -j ${chainName}

      ${optionalString ipv6Enabled ''
        ${ip6tables} -N ${chainName} 2>/dev/null || ${ip6tables} -F ${chainName}

        ${ip6tables} -A ${chainName} -m state --state ESTABLISHED,RELATED -j ACCEPT

        ${
          if interface.mode == "dnsmasq" && interface.dnsmasq.redirectDNS then
            ''
              ${ip6tables} -A ${chainName} -p udp --dport 53 -j DROP
              ${ip6tables} -A ${chainName} -p tcp --dport 53 -j DROP
            ''
          else
            optionalString interface.allowDNS ''
              ${ip6tables} -A ${chainName} -p udp --dport 53 -j ACCEPT
              ${ip6tables} -A ${chainName} -p tcp --dport 53 -j ACCEPT
            ''
        }

        ${optionalString interface.allowPrivateNetworks (
          concatMapStringsSep "\n" (
            net: "${ip6tables} -A ${chainName} -d ${net} -j ACCEPT"
          ) interface.privateNetworksV6
        )}

        ${ip6tables} -A ${chainName} -m set --match-set ${ipsetName6 name} dst -j ACCEPT

        ${ip6tables} -A ${chainName} -j DROP

        ${ip6tables} -D FORWARD ${inputInterfaceFlag} -j ${chainName} 2>/dev/null || true
        ${ip6tables} -I FORWARD 1 ${inputInterfaceFlag} -j ${chainName}
      ''}
    '';

  cleanupRules =
    name: interface:
    let
      chainName = "EGRESS_FILTER_${name}";
      inputInterfaceFlag = "-i ${name} ";
    in
    optionalString interface.enable ''
      ${optionalString (interface.mode == "dnsmasq" && interface.dnsmasq.redirectDNS) ''
        ${iptables} -t nat -D PREROUTING ${inputInterfaceFlag}-p udp --dport 53 -j DNAT --to-destination ${interface.dnsmasq.listenAddress}:${toString interface.dnsmasq.port} 2>/dev/null || true
        ${iptables} -t nat -D PREROUTING ${inputInterfaceFlag}-p tcp --dport 53 -j DNAT --to-destination ${interface.dnsmasq.listenAddress}:${toString interface.dnsmasq.port} 2>/dev/null || true
      ''}

      ${iptables} -D FORWARD ${inputInterfaceFlag}-j ${chainName} 2>/dev/null || true
      ${iptables} -F ${chainName} 2>/dev/null || true
      ${iptables} -X ${chainName} 2>/dev/null || true

      ${optionalString ipv6Enabled ''
        ${ip6tables} -D FORWARD ${inputInterfaceFlag}-j ${chainName} 2>/dev/null || true
        ${ip6tables} -F ${chainName} 2>/dev/null || true
        ${ip6tables} -X ${chainName} 2>/dev/null || true
      ''}

      ${ipset} destroy ${ipsetName name} 2>/dev/null || true
      ${optionalString ipv6Enabled ''
        ${ipset} destroy ${ipsetName6 name} 2>/dev/null || true
      ''}
    '';

  createInitialIpsets =
    name: interface:
    optionalString interface.enable ''
      ${ipset} create -exist ${ipsetName name} hash:net family inet hashsize 1024 maxelem 65536
      ${optionalString ipv6Enabled ''
        ${ipset} create -exist ${ipsetName6 name} hash:net family inet6 hashsize 1024 maxelem 65536
      ''}
    '';

  isV6Addr = ip: hasInfix ":" ip;
  nftStaticV4 = interface: interface.allowedIPv4 ++ filter (ip: !(isV6Addr ip)) interface.allowedIPs;
  nftStaticV6 = interface: interface.allowedIPv6 ++ filter isV6Addr interface.allowedIPs;

  nftForwardChain = name: "egress_fwd_${name}";

  nftEnsureSetsCommands = name: _interface: ''
    ${nftBin} add table inet ${nftTable}
    ${nftBin} add set inet ${nftTable} ${ipsetName name} '{ type ipv4_addr; flags interval; }'
    ${optionalString ipv6Enabled ''
      ${nftBin} add set inet ${nftTable} ${ipsetName6 name} '{ type ipv6_addr; flags interval; }'
    ''}
  '';

  nftStaticIpsCommands =
    name: interface:
    let
      v4 = nftStaticV4 interface;
      v6 = nftStaticV6 interface;
    in
    ''
      ${optionalString (v4 != [ ]) ''
        ${nftBin} add element inet ${nftTable} ${ipsetName name} '{ ${concatStringsSep "," v4} }'
      ''}
      ${optionalString (ipv6Enabled && v6 != [ ]) ''
        ${nftBin} add element inet ${nftTable} ${ipsetName6 name} '{ ${concatStringsSep "," v6} }'
      ''}
    '';

  mkNftStaticIpsScript =
    name: interface:
    pkgs.writeShellScript "egress-static-ips-nft-${name}" ''
      set -euo pipefail
      ${nftStaticIpsCommands name interface}
      echo "Static IPs added for ${name} (nftables)"
    '';

  mkNftResolveScript =
    name: interface:
    pkgs.writeShellScript "egress-resolve-nft-${name}" ''
      set -euo pipefail

      SET4="${ipsetName name}"
      SET6="${ipsetName6 name}"
      TMPFILE=$(mktemp)
      TMPFILE6=$(mktemp)

      ${nftEnsureSetsCommands name interface}

      echo "Resolving domains for ${name}..."

      ${concatMapStringsSep "\n" (ip: ''
        echo "${ip}" >> "$TMPFILE"
      '') interface.allowedIPv4}

      ${optionalString ipv6Enabled (
        concatMapStringsSep "\n" (ip: ''
          echo "${ip}" >> "$TMPFILE6"
        '') interface.allowedIPv6
      )}

      ${concatMapStringsSep "\n" (ip: ''
        if echo "${ip}" | ${grep} -qE ':'; then
          ${optionalString ipv6Enabled ''echo "${ip}" >> "$TMPFILE6"''}
        else
          echo "${ip}" >> "$TMPFILE"
        fi
      '') interface.allowedIPs}

      ${concatMapStringsSep "\n" (domain: ''
        echo "Resolving ${domain}..."
        ${dig} +short ${domain} A @${head interface.dnsServers} 2>/dev/null | ${grep} -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >> "$TMPFILE" || true
        ${optionalString ipv6Enabled ''
          ${dig} +short ${domain} AAAA @${head interface.dnsServers} 2>/dev/null | ${grep} -E '^[0-9a-fA-F:]+$' >> "$TMPFILE6" || true
        ''}
        for cname in $(${dig} +short ${domain} CNAME @${head interface.dnsServers} 2>/dev/null || true); do
          ${dig} +short "$cname" A @${head interface.dnsServers} 2>/dev/null | ${grep} -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >> "$TMPFILE" || true
          ${optionalString ipv6Enabled ''
            ${dig} +short "$cname" AAAA @${head interface.dnsServers} 2>/dev/null | ${grep} -E '^[0-9a-fA-F:]+$' >> "$TMPFILE6" || true
          ''}
        done
      '') interface.domains}

      # Atomic rebuild: flush + repopulate in ONE nft -f transaction, so
      # the live FORWARD chain never matches a half-built set -- the same
      # guarantee the iptables path gets from `ipset swap`.
      NFTFILE=$(mktemp)
      {
        echo "flush set inet ${nftTable} $SET4"
        V4LIST=$(${sort} -u "$TMPFILE" | ${paste} -sd, -)
        if [ -n "$V4LIST" ]; then
          echo "add element inet ${nftTable} $SET4 { $V4LIST }"
        fi
        ${optionalString ipv6Enabled ''
          echo "flush set inet ${nftTable} $SET6"
          V6LIST=$(${sort} -u "$TMPFILE6" | ${paste} -sd, -)
          if [ -n "$V6LIST" ]; then
            echo "add element inet ${nftTable} $SET6 { $V6LIST }"
          fi
        ''}
      } > "$NFTFILE"

      ${nftBin} -f "$NFTFILE"
      rm -f "$TMPFILE" "$TMPFILE6" "$NFTFILE"

      echo "Egress filter for ${name} updated (nftables)"
    '';

  nftForwardChainCommands =
    name: interface:
    let
      chain = nftForwardChain name;
      listenAddr = interface.dnsmasq.listenAddress;
      dnsPort = toString interface.dnsmasq.port;
      set4 = ipsetName name;
      set6 = ipsetName6 name;
      isDnsmasqRedirect = interface.mode == "dnsmasq" && interface.dnsmasq.redirectDNS;
    in
    optionalString interface.enable ''
      ${nftBin} add chain inet ${nftTable} ${chain}
      ${nftBin} add rule inet ${nftTable} ${chain} ct state established,related accept

      ${
        if isDnsmasqRedirect then
          ''
            ${nftBin} add rule inet ${nftTable} ${chain} ip daddr ${listenAddr} udp dport ${dnsPort} accept
            ${nftBin} add rule inet ${nftTable} ${chain} ip daddr ${listenAddr} tcp dport ${dnsPort} accept
          ''
          + optionalString ipv6Enabled ''
            ${nftBin} add rule inet ${nftTable} ${chain} meta nfproto ipv6 udp dport 53 drop
            ${nftBin} add rule inet ${nftTable} ${chain} meta nfproto ipv6 tcp dport 53 drop
          ''
        else
          optionalString interface.allowDNS ''
            ${nftBin} add rule inet ${nftTable} ${chain} udp dport 53 accept
            ${nftBin} add rule inet ${nftTable} ${chain} tcp dport 53 accept
          ''
      }

      ${optionalString interface.allowPrivateNetworks (
        concatMapStringsSep "\n" (
          net: "${nftBin} add rule inet ${nftTable} ${chain} ip daddr ${net} accept"
        ) interface.privateNetworksV4
      )}
      ${optionalString (interface.allowPrivateNetworks && ipv6Enabled) (
        concatMapStringsSep "\n" (
          net: "${nftBin} add rule inet ${nftTable} ${chain} ip6 daddr ${net} accept"
        ) interface.privateNetworksV6
      )}

      ${nftBin} add rule inet ${nftTable} ${chain} ip daddr @${set4} accept
      ${optionalString ipv6Enabled ''
        ${nftBin} add rule inet ${nftTable} ${chain} ip6 daddr @${set6} accept
      ''}

      ${nftBin} add rule inet ${nftTable} ${chain} drop
    '';

  nftDeleteForwardChainCommand =
    name: interface:
    optionalString interface.enable "${nftBin} delete chain inet ${nftTable} ${nftForwardChain name} 2>/dev/null || true";

  nftNatCommands =
    name: interface:
    optionalString (interface.enable && interface.mode == "dnsmasq" && interface.dnsmasq.redirectDNS) ''
      ${nftBin} add rule inet ${nftTable} nat_dispatch iifname "${name}" udp dport 53 dnat ip to ${interface.dnsmasq.listenAddress}:${toString interface.dnsmasq.port}
      ${nftBin} add rule inet ${nftTable} nat_dispatch iifname "${name}" tcp dport 53 dnat ip to ${interface.dnsmasq.listenAddress}:${toString interface.dnsmasq.port}
    '';

  nftDispatchCommand =
    name: interface:
    optionalString interface.enable ''
      ${nftBin} add rule inet ${nftTable} fwd_dispatch iifname "${name}" jump ${nftForwardChain name}
    '';

  nftSetupScript = pkgs.writeShellScript "egress-filter-nftables-setup" ''
    set -euo pipefail
    NFT=${nftBin}

    $NFT add table inet ${nftTable}

    ${concatStringsSep "\n" (mapAttrsToList nftEnsureSetsCommands enabledInterfaces)}
    ${concatStringsSep "\n" (mapAttrsToList nftStaticIpsCommands enabledInterfaces)}

    $NFT delete chain inet ${nftTable} nat_dispatch 2>/dev/null || true
    $NFT add chain inet ${nftTable} nat_dispatch '{ type nat hook prerouting priority dstnat - 10 ; }'
    ${concatStringsSep "\n" (mapAttrsToList nftNatCommands enabledInterfaces)}

    $NFT delete chain inet ${nftTable} fwd_dispatch 2>/dev/null || true
    ${concatStringsSep "\n" (mapAttrsToList nftDeleteForwardChainCommand enabledInterfaces)}
    ${concatStringsSep "\n" (mapAttrsToList nftForwardChainCommands enabledInterfaces)}
    $NFT add chain inet ${nftTable} fwd_dispatch '{ type filter hook forward priority filter - 10 ; }'
    ${concatStringsSep "\n" (mapAttrsToList nftDispatchCommand enabledInterfaces)}
  '';

  nftTeardownScript = pkgs.writeShellScript "egress-filter-nftables-teardown" ''
    ${nftBin} delete chain inet ${nftTable} fwd_dispatch 2>/dev/null || true
    ${concatStringsSep "\n" (mapAttrsToList nftDeleteForwardChainCommand enabledInterfaces)}
    ${nftBin} delete chain inet ${nftTable} nat_dispatch 2>/dev/null || true
  '';

  enabledInterfaces = filterAttrs (_name: iface: iface.enable) cfg.interfaces;

  resolveInterfaces = filterAttrs (_name: iface: iface.mode == "resolve") enabledInterfaces;

  dnsmasqInterfaces = filterAttrs (_name: iface: iface.mode == "dnsmasq") enabledInterfaces;

in
{
  options.services.egressFilter = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable DNS-based egress filtering";
    };

    updateInterval = mkOption {
      type = types.str;
      default = "5m";
      description = ''
        How often to re-resolve domains and update the ipsets (resolve mode only).
        Uses systemd calendar format.
      '';
    };

    interfaces = mkOption {
      type = types.attrsOf (types.submodule interfaceOptions);
      default = { };
      example = literalExpression ''
        {
          virbr0 = {
            enable = true;
            mode = "resolve";
            domains = [ "example.com" ];
            allowedIPs = [ "8.8.8.8" ];
          };

          virbr1 = {
            enable = true;
            mode = "dnsmasq";
            domains = [
              "example.com"
              "cdn.example.org"
            ];
            allowedIPs = [ "8.8.8.8" "2606:4700:4700::1111" ];
            dnsmasq.listenAddress = "192.168.100.1";
          };
        }
      '';
      description = "Per-interface egress filtering rules";
    };
  };

  config = mkIf (cfg.enable && enabledInterfaces != { }) {
    warnings = optional (nft && (config.networking.nftables.flushRuleset or false)) ''
      services.egressFilter is enabled on the nftables backend, and
      networking.nftables.flushRuleset is true. Every start or reload of
      nftables.service (including ones triggered by unrelated firewall
      config elsewhere on this host) runs `flush ruleset`, which wipes
      this module's self-managed "egress-filter" table -- including its
      dynamic allow-sets (the IPs the resolve-mode timer or the dnsmasq
      interceptor already learned) -- back to empty. Between that flush
      and this module's own systemd unit re-running, the affected
      interfaces are NOT filtered at all (fail-open, not fail-closed).
      See this module's README ("nftables backend") for detail; consider
      setting networking.nftables.flushRuleset = false if nothing else on
      this host depends on it.
    '';

    networking.firewall.enable = true;

    environment.systemPackages = [
      pkgs.ipset
      pkgs.iptables
      pkgs.dnsutils
    ]
    ++ optional (dnsmasqInterfaces != { }) pkgs.dnsmasq
    ++ optional nft pkgs.nftables;

    networking.firewall.extraPackages = [ pkgs.ipset ];

    networking.firewall.extraCommands = optionalString (!nft) ''
      ${concatStringsSep "\n" (mapAttrsToList createInitialIpsets enabledInterfaces)}

      ${concatStringsSep "\n" (mapAttrsToList generateIptablesRules enabledInterfaces)}
    '';

    networking.firewall.extraStopCommands = optionalString (!nft) ''
      ${concatStringsSep "\n" (mapAttrsToList cleanupRules enabledInterfaces)}
    '';

    systemd.services =
      (optionalAttrs nft {
        egress-filter-nftables = {
          description = "egress-filter nftables table (per-interface allow-sets + forward/nat enforcement chains)";
          after = [
            "network-pre.target"
            "nftables.service"
          ];
          wants = [ "network-pre.target" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${nftSetupScript}";
            ExecStop = "${nftTeardownScript}";
          };
        };
      })
      // (mapAttrs' (
        name: interface:
        nameValuePair "egress-filter-resolve-${name}" {
          description = "Resolve domains for egress filter on ${name}";
          after = [
            "network-online.target"
          ]
          ++ (if nft then [ "egress-filter-nftables.service" ] else [ "firewall.service" ]);
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            Type = "oneshot";
            ExecStart = if nft then mkNftResolveScript name interface else mkResolveScript name interface;
            RemainAfterExit = false;
          };
        }
      ) resolveInterfaces)
      // (mapAttrs' (
        name: interface:
        nameValuePair "egress-filter-dnsmasq-${name}" {
          description = "Dnsmasq DNS interceptor for egress filter on ${name}";
          after = [
            "network-online.target"
          ]
          ++ (if nft then [ "egress-filter-nftables.service" ] else [ "firewall.service" ]);
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];

          preStart =
            if nft then
              nftEnsureSetsCommands name interface
            else
              ''
                ${ipset} create -exist ${ipsetName name} hash:net family inet hashsize 1024 maxelem 65536
                ${optionalString ipv6Enabled ''
                  ${ipset} create -exist ${ipsetName6 name} hash:net family inet6 hashsize 1024 maxelem 65536
                ''}
              '';

          serviceConfig = {
            Type = "simple";
            ExecStart = "${pkgs.dnsmasq}/bin/dnsmasq -k -C ${mkDnsmasqConfig name interface}";
            ExecStartPost =
              if nft then mkNftStaticIpsScript name interface else mkStaticIpsScript name interface;
            Restart = "on-failure";
            RestartSec = "5s";
          };
        }
      ) dnsmasqInterfaces);

    systemd.timers = mapAttrs' (
      name: _interface:
      nameValuePair "egress-filter-resolve-${name}" {
        description = "Periodically resolve domains for egress filter on ${name}";
        wantedBy = [ "timers.target" ];

        timerConfig = {
          OnBootSec = "1m";
          OnUnitActiveSec = cfg.updateInterval;
          RandomizedDelaySec = "30s";
        };
      }
    ) resolveInterfaces;
  };
}
