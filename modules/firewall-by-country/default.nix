# firewall-by-country — geo-filter inbound traffic with ipset + iptables
#
# A NixOS module that builds per-country ipset hash tables from prefix lists
# and inserts an iptables/ip6tables chain (v4 + v6) at INPUT position 1 to
# allow- or block-list traffic by the source IP's country.
#
# THE LOAD-BEARING TRAP (do not remove any RETURN rule below):
# Before the country DROP you MUST `RETURN` on ESTABLISHED/RELATED and on
# every private / loopback / link-local range PLUS CGNAT 100.64.0.0/10
# (RFC 6598) — and, for v6, on your overlay/mesh ULA prefix. Otherwise an
# allowlist silently locks out return traffic and your own management network
# (VPN / mesh / tailnet). Matching is on SOURCE IP only, and the chain is
# inserted at INPUT position 1 so it runs ahead of the rest of
# networking.firewall.
#
# You must supply the prefix lists yourself (there is no upstream package):
# set `geoipPackage` to a derivation laying out
#   share/geoip-country-lists/<cc>/ipv4-aggregated.txt
#   share/geoip-country-lists/<cc>/ipv6-aggregated.txt
# one CIDR per line ('#' comments ignored). Sources for such lists include
# ipdeny.com aggregated zones or a MaxMind GeoLite2 export.

{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.services.firewallByCountry;

  geoipCountryLists = cfg.geoipPackage;

  uppercaseCountries = map toUpper cfg.countries;

  ipv6Enabled = config.networking.enableIPv6;

  # Ranges that must always bypass the country check. The v4 defaults are the
  # standard RFC 1918 private ranges, loopback, link-local, and the RFC 6598
  # CGNAT block (100.64.0.0/10) — many mesh/VPN overlays (e.g. Tailscale) hand
  # out addresses inside CGNAT, so dropping it would lock out your own tunnel.
  # Append your own via extraAllowedRangesV4 / extraAllowedRangesV6.
  allowRangesV4 = [
    "127.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "169.254.0.0/16"
  ] ++ cfg.extraAllowedRangesV4;

  # v6 defaults: loopback, link-local, and unique-local (fc00::/7 covers ULA).
  # If your mesh/VPN uses a ULA prefix outside fc00::/7, or you want it listed
  # explicitly, add it to extraAllowedRangesV6 (Tailscale's default is
  # fd7a:115c:a1e0::/48).
  allowRangesV6 = [
    "::1/128"
    "fe80::/10"
    "fc00::/7"
  ] ++ cfg.extraAllowedRangesV6;

  interfaceOptions =
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          description = "The name of the network interface";
        };

        enable = mkEnableOption "Country-based IP filtering for this interface";

        mode = mkOption {
          type = types.enum [
            "allowlist"
            "blocklist"
          ];
          default = cfg.mode;
          description = ''
            Mode of operation for this interface:
              - allowlist: only allow traffic from listed countries
              - blocklist: block traffic from listed countries
          '';
        };

        countries = mkOption {
          type = types.listOf (types.strMatching "^[A-Za-z]{2}$");
          default = [ ];
          example = [
            "US"
            "DE"
            "FR"
          ];
          description = ''
            List of two-letter country codes (ISO 3166-1 alpha-2, case-insensitive)
            to either allow or block on this interface, depending on mode.
          '';
        };
      };
    };

  allCountries = unique (
    uppercaseCountries
    ++ (flatten (
      mapAttrsToList (
        name: interface: if interface.enable then map toUpper interface.countries else [ ]
      ) cfg.interfaces
    ))
  );

  # nixpkgs' nftables-based firewall (firewall-nftables.nix) hard-asserts
  # networking.firewall.extraCommands/extraStopCommands == "" -- the
  # INPUT-position-1 jump chains below can't be driven through them on that
  # backend. Instead this builds its own nftables table (family inet, name
  # firewall-by-country) OUTSIDE `networking.nftables.tables`: unlike the
  # fail2ban-ipset-geoip-cloudflare recipe, there's no accumulated runtime
  # state to protect here (the country sets are fully rebuilt from
  # geoipPackage on every run regardless of backend), so the nftables path
  # just deletes the whole table if present and recreates it from scratch in
  # one atomic `nft -f` transaction -- no delta/preservation logic needed.
  #
  # Each per-interface chain and the global chain become their own nftables
  # chain (not a base chain), jumped to from one dispatcher base chain hooked
  # at a priority earlier than nixos-fw's (`filter - 10`), in the same order
  # the iptables path ends up with after its repeated `-I INPUT 1` inserts:
  # per-interface chains first, the global chain last. `return` inside a
  # jumped-to chain resumes the dispatcher at the next jump -- the nftables
  # equivalent of iptables' "RETURN to INPUT, fall through to the next -j
  # rule" -- so the established/related and bypass-range RETURN rules keep
  # exactly the same "skip this scope's country check, but still let a later
  # scope (and, if nothing terminates, nixos-fw itself) see the packet"
  # meaning. An explicit accept/drop, by contrast, is terminal immediately
  # (matching iptables ACCEPT/DROP), including the unconditional
  # default-action rule at the end of each chain.
  nft = config.networking.firewall.backend == "nftables";
  nftBin = "${pkgs.nftables}/bin/nft";
  nftCountrySet = country: "country_${country}";
  nftCountrySet6 = country: "country6_${country}";

  nftDeleteTable = "${nftBin} delete table inet firewall-by-country 2>/dev/null || true";

  # Rule body (no chain wrapper) for one scope: the global filter, or one
  # interface's filter. Mirrors generateIptablesRules one-for-one.
  nftScopeRules =
    {
      enable,
      mode,
      countries,
    }:
    let
      targetAction = if mode == "allowlist" then "accept" else "drop";
      defaultAction = if mode == "allowlist" then "drop" else "accept";
      uc = map toUpper countries;
    in
    optionalString enable ''
      ct state established,related return
      ${concatMapStrings (range: ''
        ip saddr ${range} return
        ip daddr ${range} return
      '') allowRangesV4}
      ${optionalString ipv6Enabled (
        concatMapStrings (range: ''
          ip6 saddr ${range} return
          ip6 daddr ${range} return
        '') allowRangesV6
      )}
      ${concatMapStrings (country: "ip saddr @${nftCountrySet country} ${targetAction}\n") uc}
      ${optionalString ipv6Enabled (
        concatMapStrings (country: "ip6 saddr @${nftCountrySet6 country} ${targetAction}\n") uc
      )}
      ${defaultAction}
    '';

  nftRuleset = ''
    table inet firewall-by-country {
      ${concatMapStrings (
        country: "set ${nftCountrySet country} { type ipv4_addr; flags interval; }\n"
      ) allCountries}
      ${optionalString ipv6Enabled (
        concatMapStrings (
          country: "set ${nftCountrySet6 country} { type ipv6_addr; flags interval; }\n"
        ) allCountries
      )}

      ${optionalString cfg.enable ''
        chain country_global {
          ${nftScopeRules {
            enable = cfg.enable;
            mode = cfg.mode;
            countries = cfg.countries;
          }}
        }
      ''}

      ${concatStringsSep "\n" (
        mapAttrsToList (
          name: interface:
          optionalString interface.enable ''
            chain country_${name} {
              ${nftScopeRules {
                enable = interface.enable;
                mode = interface.mode;
                countries = interface.countries;
              }}
            }
          ''
        ) cfg.interfaces
      )}

      chain input {
        type filter hook input priority filter - 10;
        ${concatStringsSep "\n" (
          mapAttrsToList (
            name: interface: optionalString interface.enable ''iifname "${name}" jump country_${name}''
          ) cfg.interfaces
        )}
        ${optionalString cfg.enable "jump country_global"}
      }
    }
  '';

  # Runtime population of the per-country set elements, read from
  # geoipPackage at RUNTIME (not Nix eval time) so referencing it never
  # forces an import-from-derivation build during evaluation -- same
  # constraint and same technique as the iptables-path createIpsetCommands.
  nftPopulateCountrySets = countries: ''
    ${concatMapStrings (country: ''
      if [ -f "${geoipCountryLists}/share/geoip-country-lists/${toLower country}/ipv4-aggregated.txt" ]; then
        ${pkgs.gnugrep}/bin/grep -v "^#" "${geoipCountryLists}/share/geoip-country-lists/${toLower country}/ipv4-aggregated.txt" | \
          while read -r cidr; do
            [ -n "$cidr" ] && $NFT add element inet firewall-by-country ${nftCountrySet country} "{ $cidr }"
          done
      fi
    '') countries}

    ${optionalString ipv6Enabled (
      concatMapStrings (country: ''
        if [ -f "${geoipCountryLists}/share/geoip-country-lists/${toLower country}/ipv6-aggregated.txt" ]; then
          ${pkgs.gnugrep}/bin/grep -v "^#" "${geoipCountryLists}/share/geoip-country-lists/${toLower country}/ipv6-aggregated.txt" | \
            while read -r cidr; do
              [ -n "$cidr" ] && $NFT add element inet firewall-by-country ${nftCountrySet6 country} "{ $cidr }"
            done
        fi
      '') countries
    )}
  '';

  nftSetupScript = pkgs.writeShellScript "firewall-by-country-nftables-setup" ''
    set -euo pipefail
    NFT=${nftBin}

    ${nftDeleteTable}
    $NFT -f - <<'NFTEOF'
    ${nftRuleset}
    NFTEOF

    ${nftPopulateCountrySets allCountries}
  '';

  nftTeardownScript = pkgs.writeShellScript "firewall-by-country-nftables-teardown" ''
    ${nftDeleteTable}
  '';

  countryToIpset = country: "country_${country}";
  countryToIpset6 = country: "country6_${country}";
  iptables = "${pkgs.iptables}/bin/iptables";
  ip6tables = "${pkgs.iptables}/bin/ip6tables";

  createIpsetCommands = countries: ''
    ${pkgs.kmod}/bin/modprobe ip_set_hash_net
    ${pkgs.kmod}/bin/modprobe xt_set
    ${pkgs.ipset}/bin/ipset create -exist _probe hash:net family inet hashsize 64 maxelem 64
    ${pkgs.ipset}/bin/ipset destroy _probe

    IPSET_RESTORE=$(mktemp)

    ${concatMapStrings (country: ''
      echo "create -exist ${countryToIpset country} hash:net family inet hashsize 1024 maxelem 65536" >> $IPSET_RESTORE
      echo "flush ${countryToIpset country}" >> $IPSET_RESTORE
      if [ -f "${geoipCountryLists}/share/geoip-country-lists/${toLower country}/ipv4-aggregated.txt" ]; then
        ${pkgs.gnugrep}/bin/grep -v "^#" "${geoipCountryLists}/share/geoip-country-lists/${toLower country}/ipv4-aggregated.txt" | \
          ${pkgs.gawk}/bin/awk '{print "add -exist '${countryToIpset country}' " $1}' >> $IPSET_RESTORE
      fi
    '') countries}

    ${optionalString ipv6Enabled ''
      ${concatMapStrings (country: ''
        echo "create -exist ${countryToIpset6 country} hash:net family inet6 hashsize 1024 maxelem 65536" >> $IPSET_RESTORE
        echo "flush ${countryToIpset6 country}" >> $IPSET_RESTORE
        if [ -f "${geoipCountryLists}/share/geoip-country-lists/${toLower country}/ipv6-aggregated.txt" ]; then
          ${pkgs.gnugrep}/bin/grep -v "^#" "${geoipCountryLists}/share/geoip-country-lists/${toLower country}/ipv6-aggregated.txt" | \
            ${pkgs.gawk}/bin/awk '{print "add -exist '${countryToIpset6 country}' " $1}' >> $IPSET_RESTORE
        fi
      '') countries}
    ''}

    ${pkgs.ipset}/bin/ipset restore < $IPSET_RESTORE
    rm -f $IPSET_RESTORE

    ${concatMapStrings (country: ''
      ${pkgs.ipset}/bin/ipset list -n ${countryToIpset country} >/dev/null
      ${optionalString ipv6Enabled "${pkgs.ipset}/bin/ipset list -n ${countryToIpset6 country} >/dev/null"}
    '') countries}
  '';

  generateIptablesRules =
    {
      enable,
      mode,
      countries,
      interfaceName ? null,
    }:
    let
      chainSuffix = if interfaceName == null then "" else "_${interfaceName}";
      chainName = "COUNTRY_FILTER${chainSuffix}";
      sp = " ";
      interfaceFlag = if interfaceName == null then "" else "-i ${interfaceName}" + sp;

      targetAction = if mode == "allowlist" then "ACCEPT" else "DROP";
      defaultAction = if mode == "allowlist" then "DROP" else "ACCEPT";

      uppercaseInterfaceCountries = map toUpper countries;

      # RETURN on both source and destination for each bypass range, so the
      # country check never sees local/return traffic.
      returnRulesV4 = concatMapStrings (range: ''
        ${iptables} -A ${chainName} ${interfaceFlag} -s ${range} -j RETURN
        ${iptables} -A ${chainName} ${interfaceFlag} -d ${range} -j RETURN
      '') allowRangesV4;

      returnRulesV6 = concatMapStrings (range: ''
        ${ip6tables} -A ${chainName} ${interfaceFlag} -s ${range} -j RETURN
        ${ip6tables} -A ${chainName} ${interfaceFlag} -d ${range} -j RETURN
      '') allowRangesV6;
    in
    optionalString enable ''
      ${iptables} -N ${chainName} 2>/dev/null || ${iptables} -F ${chainName}

      ${iptables} -A ${chainName} ${interfaceFlag} -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

      ${returnRulesV4}

      ${concatMapStrings (country: ''
        ${iptables} -A ${chainName} ${interfaceFlag}-m set --match-set ${countryToIpset country} src -j ${targetAction}
      '') uppercaseInterfaceCountries}

      ${iptables} -A ${chainName} -j ${defaultAction}

      ${iptables} -D INPUT ${interfaceFlag}-j ${chainName} 2>/dev/null || true
      ${iptables} -I INPUT 1 ${interfaceFlag}-j ${chainName}

      ${optionalString ipv6Enabled ''
        ${ip6tables} -N ${chainName} 2>/dev/null || ${ip6tables} -F ${chainName}

        ${ip6tables} -A ${chainName} ${interfaceFlag} -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

        ${returnRulesV6}

        ${concatMapStrings (country: ''
          ${ip6tables} -A ${chainName} ${interfaceFlag}-m set --match-set ${countryToIpset6 country} src -j ${targetAction}
        '') uppercaseInterfaceCountries}

        ${ip6tables} -A ${chainName} -j ${defaultAction}

        ${ip6tables} -D INPUT ${interfaceFlag}-j ${chainName} 2>/dev/null || true
        ${ip6tables} -I INPUT 1 ${interfaceFlag}-j ${chainName}
      ''}
    '';

  cleanupRules =
    {
      enable,
      interfaceName ? null,
    }:
    let
      chainSuffix = if interfaceName == null then "" else "_${interfaceName}";
      chainName = "COUNTRY_FILTER${chainSuffix}";
      sp = " ";
      interfaceFlag = if interfaceName == null then "" else "-i ${interfaceName}" + sp;
    in
    optionalString enable ''
      ${iptables} -D INPUT ${interfaceFlag}-j ${chainName} 2>/dev/null || true
      ${iptables} -F ${chainName} 2>/dev/null || true
      ${iptables} -X ${chainName} 2>/dev/null || true

      ${optionalString ipv6Enabled ''
        ${ip6tables} -D INPUT ${interfaceFlag}-j ${chainName} 2>/dev/null || true
        ${ip6tables} -F ${chainName} 2>/dev/null || true
        ${ip6tables} -X ${chainName} 2>/dev/null || true
      ''}
    '';
in
{
  options.services.firewallByCountry = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable global country-based IP filtering";
    };

    geoipPackage = mkOption {
      type = types.nullOr types.package;
      default = null;
      example = literalExpression "pkgs.geoip-countrylist";
      description = ''
        A package providing the per-country prefix lists, laid out as
        =share/geoip-country-lists/<cc>/ipv4-aggregated.txt= and
        =share/geoip-country-lists/<cc>/ipv6-aggregated.txt=, one CIDR per
        line ('#' comments ignored). There is no upstream package for this —
        build one from a source such as ipdeny.com aggregated zones or a
        MaxMind GeoLite2 export. Required when filtering is enabled.
      '';
    };

    mode = mkOption {
      type = types.enum [
        "allowlist"
        "blocklist"
      ];
      default = "allowlist";
      description = ''
        Default mode of operation:
          - allowlist: only allow traffic from listed countries
          - blocklist: block traffic from listed countries
      '';
    };

    countries = mkOption {
      type = types.listOf (types.strMatching "^[A-Za-z]{2}$");
      default = [ ];
      example = [
        "US"
        "DE"
        "FR"
      ];
      description = ''
        List of two-letter country codes (ISO 3166-1 alpha-2, case-insensitive)
        to either allow or block globally, depending on mode.
      '';
    };

    extraAllowedRangesV4 = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "203.0.113.0/24" ];
      description = ''
        Additional IPv4 CIDR ranges that always bypass the country check
        (RETURN before the country match, on both source and destination).
        Standard private, loopback, link-local and CGNAT ranges are always
        included; use this for extra trusted networks.
      '';
    };

    extraAllowedRangesV6 = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "fd7a:115c:a1e0::/48" ];
      description = ''
        Additional IPv6 CIDR ranges that always bypass the country check.
        Loopback, link-local and unique-local (fc00::/7) are always included.
        Add your mesh/VPN overlay prefix here if it lies outside fc00::/7 or
        you want it listed explicitly (Tailscale's default is
        fd7a:115c:a1e0::/48).
      '';
    };

    interfaces = mkOption {
      type = types.attrsOf (types.submodule interfaceOptions);
      default = { };
      example = literalExpression ''
        {
          eth0 = {
            enable = true;
            mode = "allowlist";
            countries = [ "US" "CA" ];
          };
          wg0 = {
            enable = true;
            mode = "blocklist";
            countries = [ "CN" "RU" ];
          };
        }
      '';
      description = "Per-interface country filtering rules";
    };
  };

  config = mkIf (cfg.enable || any (i: i.enable) (attrValues cfg.interfaces)) {
    assertions = [
      {
        assertion = cfg.geoipPackage != null;
        message = "services.firewallByCountry: geoipPackage must be set when filtering is enabled.";
      }
    ];

    networking.firewall.enable = true;

    boot.kernelModules = optionals (!nft) [
      "ip_set_hash_net"
      "xt_set"
    ];

    environment.systemPackages =
      optionals (!nft) [
        pkgs.ipset
        pkgs.iptables
      ]
      ++ optional nft pkgs.nftables;

    networking.firewall.extraPackages = optional (!nft) pkgs.ipset;

    # iptables backend only -- see the nft/nftRuleset comment above for the
    # nftables path (its own self-managed table, rebuilt by the
    # firewall-by-country-nftables systemd unit below).
    networking.firewall.extraCommands = optionalString (!nft) ''
      ${optionalString (allCountries != [ ]) (createIpsetCommands allCountries)}

      ${generateIptablesRules {
        enable = cfg.enable;
        mode = cfg.mode;
        countries = cfg.countries;
      }}

      ${concatStringsSep "\n" (
        mapAttrsToList (
          name: interface:
          generateIptablesRules {
            enable = interface.enable;
            mode = interface.mode;
            countries = interface.countries;
            interfaceName = name;
          }
        ) cfg.interfaces
      )}
    '';

    networking.firewall.extraStopCommands = optionalString (!nft) ''
      ${cleanupRules { enable = cfg.enable; }}

      ${concatStringsSep "\n" (
        mapAttrsToList (
          name: interface:
          cleanupRules {
            enable = interface.enable;
            interfaceName = name;
          }
        ) cfg.interfaces
      )}

      ${concatMapStrings (country: ''
        ${pkgs.ipset}/bin/ipset destroy ${countryToIpset country} 2>/dev/null || true
        ${optionalString ipv6Enabled "${pkgs.ipset}/bin/ipset destroy ${countryToIpset6 country} 2>/dev/null || true"}
      '') allCountries}
    '';

    systemd.services.firewall-by-country-nftables = mkIf nft {
      description = "firewall-by-country nftables table (per-country sets + INPUT jump chains)";
      after = [ "network-pre.target" ];
      wants = [ "network-pre.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${nftSetupScript}";
        ExecStop = "${nftTeardownScript}";
      };
    };
  };
}
