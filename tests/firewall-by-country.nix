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
    AR = buildTestIP "ar";
    PE = buildTestIP "pe";
  };

  countries = {
    # Allowlist mode: only allows connections from Argentina
    spain = {
      code = "ES";
      ip = testIPs.ES;
      firewall = {
        mode = "allowlist";
        countries = [ "AR" ];
      };
    };
    # Allowlist mode: allows connections from Spain and Peru
    argentina = {
      code = "AR";
      ip = testIPs.AR;
      firewall = {
        mode = "allowlist";
        countries = [ "ES" "PE" ];
      };
    };
    # Blocklist mode: blocks connections from Spain, allows Argentina
    peru = {
      code = "PE";
      ip = testIPs.PE;
      firewall = {
        mode = "blocklist";
        countries = [ "ES" ];
      };
    };
  };

  # Expected connectivity matrix (true = connection allowed)
  # For bidirectional connectivity, BOTH sides must allow the other.
  #
  # Tests covered:
  # - Allowlist allowed: spain->argentina (AR in spain's allowlist, ES in argentina's allowlist)
  # - Allowlist allowed: argentina->spain (ES in argentina's allowlist, AR in spain's allowlist)
  # - Allowlist allowed: argentina->peru (PE in argentina's allowlist, AR not in peru's blocklist)
  # - Allowlist blocked: spain->peru (PE not in spain's allowlist)
  # - Blocklist allowed: peru->argentina (AR not in peru's blocklist, PE in argentina's allowlist)
  # - Blocklist blocked: peru->spain (ES in peru's blocklist)
  connectivityMatrix = {
    spain = {
      argentina = true; # AR in spain's allowlist, ES in argentina's allowlist
      peru = false; # PE not in spain's allowlist
    };
    argentina = {
      spain = true; # ES in argentina's allowlist, AR in spain's allowlist
      peru = true; # PE in argentina's allowlist, AR not in peru's blocklist
    };
    peru = {
      spain = false; # ES in peru's blocklist
      argentina = true; # AR not in peru's blocklist, PE in argentina's allowlist
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
