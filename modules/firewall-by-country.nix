{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.firewallByCountry;

  # Get the geoip-countrylist package
  geoipCountryLists = cfg.geoipPackage;

  # Convert country codes to uppercase for consistency
  uppercaseCountries = map toUpper cfg.countries;

  # Interface-specific options
  interfaceOptions = {name, ...}: {
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
        default = [];
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

  # Get all unique countries used in the configuration
  allCountries = unique (
    uppercaseCountries
    ++ (flatten (
      mapAttrsToList (
        name: interface:
          if interface.enable
          then map toUpper interface.countries
          else []
      )
      cfg.interfaces
    ))
  );

  # Check if IPv6 is enabled in the system
  ipv6Enabled = config.networking.enableIPv6;

  # Helper to create ipset name
  countryToIpset = country: "country_${country}";
  countryToIpset6 = country: "country6_${country}";
  iptables = "${pkgs.iptables}/bin/iptables";
  ip6tables = "${pkgs.iptables}/bin/ip6tables";

  # Create ipset restore commands for a list of countries
  createIpsetCommands = countries: ''
    # Create temporary file for ipset restore
    IPSET_RESTORE=$(mktemp)

    # IPv4 ipsets
    ${concatMapStrings (country: ''
        echo "create -exist ${countryToIpset country} hash:net family inet hashsize 1024 maxelem 65536" >> $IPSET_RESTORE
        echo "flush ${countryToIpset country}" >> $IPSET_RESTORE
        if [ -f "${geoipCountryLists}/share/geoip-countrylist/${toLower country}/ipv4-aggregated.txt" ]; then
          ${pkgs.gnugrep}/bin/grep -v "^#" "${geoipCountryLists}/share/geoip-countrylist/${toLower country}/ipv4-aggregated.txt" | \
            ${pkgs.gawk}/bin/awk '{print "add -exist '${countryToIpset country}' " $1}' >> $IPSET_RESTORE
        fi
      '')
      countries}

    ${optionalString ipv6Enabled ''
      # IPv6 ipsets
      ${concatMapStrings (country: ''
          echo "create -exist ${countryToIpset6 country} hash:net family inet6 hashsize 1024 maxelem 65536" >> $IPSET_RESTORE
          echo "flush ${countryToIpset6 country}" >> $IPSET_RESTORE
          if [ -f "${geoipCountryLists}/share/geoip-countrylist/${toLower country}/ipv6-aggregated.txt" ]; then
            ${pkgs.gnugrep}/bin/grep -v "^#" "${geoipCountryLists}/share/geoip-countrylist/${toLower country}/ipv6-aggregated.txt" | \
              ${pkgs.gawk}/bin/awk '{print "add -exist '${countryToIpset6 country}' " $1}' >> $IPSET_RESTORE
          fi
        '')
        countries}
    ''}

    # Apply all ipset commands at once
    ${pkgs.ipset}/bin/ipset restore -! < $IPSET_RESTORE
    rm -f $IPSET_RESTORE
  '';

  # Generate iptables rules for country filtering
  generateIptablesRules = {
    enable,
    mode,
    countries,
    interfaceName ? null,
  }: let
    chainSuffix =
      if interfaceName == null
      then ""
      else "_${interfaceName}";
    chainName = "COUNTRY_FILTER${chainSuffix}";
    interfaceFlag =
      if interfaceName == null
      then ""
      else "-i ${interfaceName} ";

    # Determine actions based on mode
    targetAction =
      if mode == "allowlist"
      then "ACCEPT"
      else "DROP";
    defaultAction =
      if mode == "allowlist"
      then "DROP"
      else "ACCEPT";

    uppercaseInterfaceCountries = map toUpper countries;
  in
    optionalString enable ''
      # Create chain for country filtering (IPv4)
      ${iptables} -N ${chainName} 2>/dev/null || ${iptables} -F ${chainName}

      # Allow private and local networks (IPv4)
      ${iptables} -A ${chainName} ${interfaceFlag}-s 127.0.0.0/8 -j RETURN
      ${iptables} -A ${chainName} ${interfaceFlag}-d 127.0.0.0/8 -j RETURN
      ${iptables} -A ${chainName} ${interfaceFlag}-s 10.0.0.0/8 -j RETURN
      ${iptables} -A ${chainName} ${interfaceFlag}-d 10.0.0.0/8 -j RETURN
      ${iptables} -A ${chainName} ${interfaceFlag}-s 100.64.0.0/10 -j RETURN
      ${iptables} -A ${chainName} ${interfaceFlag}-d 100.64.0.0/10 -j RETURN
      ${iptables} -A ${chainName} ${interfaceFlag}-s 172.16.0.0/12 -j RETURN
      ${iptables} -A ${chainName} ${interfaceFlag}-d 172.16.0.0/12 -j RETURN
      ${iptables} -A ${chainName} ${interfaceFlag}-s 192.168.0.0/16 -j RETURN
      ${iptables} -A ${chainName} ${interfaceFlag}-d 192.168.0.0/16 -j RETURN
      ${iptables} -A ${chainName} ${interfaceFlag}-s 169.254.0.0/16 -j RETURN
      ${iptables} -A ${chainName} ${interfaceFlag}-d 169.254.0.0/16 -j RETURN

      # Add country rules (IPv4)
      ${concatMapStrings (country: ''
          ${iptables} -A ${chainName} ${interfaceFlag}-m set --match-set ${countryToIpset country} src -j ${targetAction}
        '')
        uppercaseInterfaceCountries}

      # Default action at the end of the chain
      ${iptables} -A ${chainName} -j ${defaultAction}

      # Insert into INPUT chain
      ${iptables} -D INPUT ${interfaceFlag}-j ${chainName} 2>/dev/null || true
      ${iptables} -I INPUT 1 ${interfaceFlag}-j ${chainName}

      ${optionalString ipv6Enabled ''
        # Create chain for country filtering (IPv6)
        ${ip6tables} -N ${chainName} 2>/dev/null || ${ip6tables} -F ${chainName}

        # Allow private and local networks (IPv6)
        ${ip6tables} -A ${chainName} ${interfaceFlag}-s ::1/128 -j RETURN
        ${ip6tables} -A ${chainName} ${interfaceFlag}-d ::1/128 -j RETURN
        ${ip6tables} -A ${chainName} ${interfaceFlag}-s fe80::/10 -j RETURN
        ${ip6tables} -A ${chainName} ${interfaceFlag}-d fe80::/10 -j RETURN
        ${ip6tables} -A ${chainName} ${interfaceFlag}-s fc00::/7 -j RETURN
        ${ip6tables} -A ${chainName} ${interfaceFlag}-d fc00::/7 -j RETURN
        ${ip6tables} -A ${chainName} ${interfaceFlag}-s fd7a:115c:a1e0::/48 -j RETURN
        ${ip6tables} -A ${chainName} ${interfaceFlag}-d fd7a:115c:a1e0::/48 -j RETURN

        # Add country rules (IPv6)
        ${concatMapStrings (country: ''
            ${ip6tables} -A ${chainName} ${interfaceFlag}-m set --match-set ${countryToIpset6 country} src -j ${targetAction}
          '')
          uppercaseInterfaceCountries}

        # Default action at the end of the chain
        ${ip6tables} -A ${chainName} -j ${defaultAction}

        # Insert into INPUT chain
        ${ip6tables} -D INPUT ${interfaceFlag}-j ${chainName} 2>/dev/null || true
        ${ip6tables} -I INPUT 1 ${interfaceFlag}-j ${chainName}
      ''}
    '';

  # Cleanup commands for rules
  cleanupRules = {
    enable,
    interfaceName ? null,
  }: let
    chainSuffix =
      if interfaceName == null
      then ""
      else "_${interfaceName}";
    chainName = "COUNTRY_FILTER${chainSuffix}";
    interfaceFlag =
      if interfaceName == null
      then ""
      else "-i ${interfaceName} ";
  in
    optionalString enable ''
      # Remove from INPUT chain and delete chain (IPv4)
      ${iptables} -D INPUT ${interfaceFlag}-j ${chainName} 2>/dev/null || true
      ${iptables} -F ${chainName} 2>/dev/null || true
      ${iptables} -X ${chainName} 2>/dev/null || true

      ${optionalString ipv6Enabled ''
        # Remove from INPUT chain and delete chain (IPv6)
        ${ip6tables} -D INPUT ${interfaceFlag}-j ${chainName} 2>/dev/null || true
        ${ip6tables} -F ${chainName} 2>/dev/null || true
        ${ip6tables} -X ${chainName} 2>/dev/null || true
      ''}
    '';
in {
  options.services.firewallByCountry = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable global country-based IP filtering";
    };

    geoipPackage = mkOption {
      type = types.nullOr types.package;
      default = pkgs.geoip-countrylist;
      defaultText = literalExpression "pkgs.geoip-countrylist";
      description = ''
        The geoip-countrylist package to use for country IP lists.
        Override this if you don't want to use the overlay.
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
      default = [
        "AR" # Argentina
        "BR" # Brazil
        "CL" # Chile
        "CH" # Switzerland
        "DE" # Germany
        "ES" # Spain
        "FR" # France
        "MX" # Mexico
        "NL" # Netherlands
        "US" # USA
        "UY" # Uruguay
      ];
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

    interfaces = mkOption {
      type = types.attrsOf (types.submodule interfaceOptions);
      default = {};
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
    # Ensure firewall is enabled
    networking.firewall.enable = true;

    # Add required packages
    environment.systemPackages = [
      pkgs.ipset
      pkgs.iptables
    ];

    # Add ipset to firewall extra packages
    networking.firewall.extraPackages = [pkgs.ipset];

    # Create ipsets and rules during firewall start
    networking.firewall.extraCommands = ''
      # Create ipsets for all countries
      ${optionalString (allCountries != []) (createIpsetCommands allCountries)}

      # Global country filtering
      ${generateIptablesRules {
        enable = cfg.enable;
        mode = cfg.mode;
        countries = cfg.countries;
      }}

      # Per-interface country filtering
      ${concatStringsSep "\n" (
        mapAttrsToList (
          name: interface:
            generateIptablesRules {
              enable = interface.enable;
              mode = interface.mode;
              countries = interface.countries;
              interfaceName = name;
            }
        )
        cfg.interfaces
      )}
    '';

    # Clean up on firewall stop
    networking.firewall.extraStopCommands = ''
      # Clean up global rules
      ${cleanupRules {enable = cfg.enable;}}

      # Clean up per-interface rules
      ${concatStringsSep "\n" (
        mapAttrsToList (
          name: interface:
            cleanupRules {
              enable = interface.enable;
              interfaceName = name;
            }
        )
        cfg.interfaces
      )}

      # Destroy ipsets
      ${concatMapStrings (country: ''
          ${pkgs.ipset}/bin/ipset destroy ${countryToIpset country} 2>/dev/null || true
          ${optionalString ipv6Enabled "${pkgs.ipset}/bin/ipset destroy ${countryToIpset6 country} 2>/dev/null || true"}
        '')
        allCountries}
    '';
  };
}
