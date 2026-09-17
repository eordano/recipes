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

  allowRangesV4 = [
    "127.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "169.254.0.0/16"
  ]
  ++ cfg.extraAllowedRangesV4;

  allowRangesV6 = [
    "::1/128"
    "fe80::/10"
    "fc00::/7"
  ]
  ++ cfg.extraAllowedRangesV6;

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
        _name: interface: if interface.enable then map toUpper interface.countries else [ ]
      ) cfg.interfaces
    ))
  );

  nft = config.networking.firewall.backend == "nftables";
  nftBin = "${pkgs.nftables}/bin/nft";
  nftCountrySet = country: "country_${country}";
  nftCountrySet6 = country: "country6_${country}";

  nftDeleteTable = "${nftBin} delete table inet firewall-by-country 2>/dev/null || true";

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
            inherit (cfg) enable;
            inherit (cfg) mode;
            inherit (cfg) countries;
          }}
        }
      ''}

      ${concatStringsSep "\n" (
        mapAttrsToList (
          name: interface:
          optionalString interface.enable ''
            chain country_${name} {
              ${nftScopeRules {
                inherit (interface) enable;
                inherit (interface) mode;
                inherit (interface) countries;
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
        line ('#' comments ignored). There is no upstream package for this --
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

    networking.firewall.extraCommands = optionalString (!nft) ''
      ${optionalString (allCountries != [ ]) (createIpsetCommands allCountries)}

      ${generateIptablesRules {
        inherit (cfg) enable;
        inherit (cfg) mode;
        inherit (cfg) countries;
      }}

      ${concatStringsSep "\n" (
        mapAttrsToList (
          name: interface:
          generateIptablesRules {
            inherit (interface) enable;
            inherit (interface) mode;
            inherit (interface) countries;
            interfaceName = name;
          }
        ) cfg.interfaces
      )}
    '';

    networking.firewall.extraStopCommands = optionalString (!nft) ''
      ${cleanupRules { inherit (cfg) enable; }}

      ${concatStringsSep "\n" (
        mapAttrsToList (
          name: interface:
          cleanupRules {
            inherit (interface) enable;
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
