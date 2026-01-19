{
  pkgs,
  lib,
  ...
}:
let
  secondsToConsiderPingFail = "2";

  buildTestIP =
    country:
    let
      countryLower = lib.toLower country;
      ipListPath = "${pkgs.geoip-countrylist}/share/geoip-countrylist/${countryLower}/ipv4-aggregated.txt";
      ipListLines = lib.splitString "\n" (builtins.readFile ipListPath);
      ipListLinesFiltered = builtins.filter (line: builtins.match "^.*/24$" line != null) ipListLines;
      firstIp = builtins.head ipListLinesFiltered;
      first24bits = builtins.head (builtins.match "^(.*)\.0/24$" firstIp);
    in
    first24bits + ".1";
  testIPs = {
    ES = buildTestIP "es";
    DE = buildTestIP "de";
    AR = buildTestIP "ar";
    PE = buildTestIP "pe";
    AU = buildTestIP "au";
  };

  countries = {
    spain = {
      code = "ES";
      ip = testIPs.ES;
      firewall = {
        mode = "allowlist";
        countries = [
          "AR"
          "DE"
        ];
      };
    };
    argentina = {
      code = "AR";
      ip = testIPs.AR;
      firewall = {
        mode = "allowlist";
        countries = [
          "ES"
          "PE"
        ];
      };
    };
    peru = {
      code = "PE";
      ip = testIPs.PE;
      firewall = {
        mode = "blocklist";
        countries = [
          "ES"
          "DE"
        ];
      };
    };
    australia = {
      code = "AU";
      ip = testIPs.AU;
      firewall = {
        mode = "blocklist";
        countries = [
          "AR"
          "ES"
        ];
      };
    };
    germany = {
      code = "DE";
      ip = testIPs.DE;
      firewall = {
        mode = "allowlist";
        countries = [
          "ES"
          "AU"
        ];
      };
    };
  };

  # Expected connectivity matrix (true = connection allowed)
  connectivityMatrix = {
    spain = {
      argentina = true;
      peru = false;
      australia = false;
      germany = true;
    };
    argentina = {
      spain = true;
      peru = true;
      australia = false;
      germany = false;
    };
    peru = {
      spain = false;
      argentina = true;
      australia = true;
      germany = false;
    };
    australia = {
      spain = false;
      argentina = false;
      peru = true;
      germany = true;
    };
    germany = {
      spain = true;
      argentina = false;
      peru = false;
      australia = true;
    };
  };

  dev = "eth1";
in
pkgs.testers.nixosTest {
  name = "country-router-test";

  nodes = lib.mapAttrs (
    name: countryConfig:
    { ... }:
    {
      imports = [ ../modules/firewall-by-country.nix ];
      virtualisation.vlans = [ 1 ];

      networking = {
        useDHCP = false;
        interfaces.${dev}.ipv4 = {
          addresses = [
            {
              address = countryConfig.ip;
              prefixLength = 0;
            }
          ];
          routes = [
            {
              address = "0.0.0.0";
              prefixLength = 0;
            }
          ];
        };
        firewall = {
          enable = true;
          allowPing = true;
        };
      };
      services = {
        firewallByCountry = countryConfig.firewall // {
          enable = true;
        };
        nginx = {
          enable = true;
          virtualHosts."_" = {
            default = true;
            locations."/" = {
              root = pkgs.writeTextDir "index.html" "<h1>${name} Server</h1>";
            };
          };
        };
      };
      environment.systemPackages = with pkgs; [
        curl
        ipset
        iptables
      ];
    }
  ) countries;

  testScript = ''
    start_all()

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: _: ''
        ${name}.wait_for_unit("network.target")
        ${name}.wait_for_unit("nginx.service")
        ${name}.wait_for_unit("firewall.service")
      '') countries
    )}

    # Show network configuration for each node
    print("\\n=== Router network configuration ===")

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: _: ''
        print("\\n== ${name} network configuration ===")
        ${name}.succeed("ip addr show")
        ${name}.succeed("ip route show")
      '') countries
    )}

    ${lib.concatStringsSep "\n" (
      lib.flatten (
        lib.mapAttrsToList (
          fromCountry: fromConfig:
          lib.mapAttrsToList (
            toCountry: toConfig:
            lib.optionalString (fromCountry != toCountry) ''
              with subtest("${fromCountry} to ${toCountry}"):
                  cmd = "curl -s --connect-timeout ${secondsToConsiderPingFail} http://${toConfig.ip}/ | grep ${toCountry}"
                  ${
                    if connectivityMatrix.${fromCountry}.${toCountry} then
                      ''
                        ${fromCountry}.succeed(cmd)
                        print("SUCCESS: connection from ${fromCountry} to ${toCountry} allowed as expected")
                      ''
                    else
                      ''
                        ${fromCountry}.fail(cmd)
                        print("SUCCESS: connection from ${fromCountry} to ${toCountry} blocked as expected")
                      ''
                  }
            ''
          ) (lib.filterAttrs (n: _: n != fromCountry) countries)
        ) countries
      )
    )}
  '';
}
