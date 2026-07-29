# Encrypted DNS (DNSCrypt / DoH) fronted by a dnsmasq cache.
#
# Two traps this module handles so you don't have to:
#
#   1. Cloaking rules from networking.hosts
#      Encrypted upstream resolution bypasses /etc/hosts. So on every preStart
#      we regenerate networking.hosts into a dnscrypt-proxy cloaking file, which
#      is how local host overrides survive an encrypted upstream.
#
#   2. Serve-stale during WAN outages / bufferbloat
#      dnsmasq's use-stale-cache keeps popular names resolving instantly from
#      expired cache entries when the upstream is briefly unreachable, instead
#      of failing the lookup.
#
# Import it and set `modules.dnscrypt-proxy.enable = true;`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.dnscrypt-proxy;
in
{
  options = {
    modules.dnscrypt-proxy = {
      enable = lib.mkEnableOption "dnscrypt-proxy";
      listenPort = lib.mkOption {
        description = "Port where the resolver should listen on (always localhost)";
        default = 53;
        type = lib.types.int;
      };
      dnsmasq = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Use dnsmasq in front of dnscrypt-proxy to cache results";
        };
        bindInterfaces = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Names of interfaces to bind (default [] binds on all)";
        };
        internalPort = lib.mkOption {
          type = lib.types.int;
          default = 10053;
          description = "Port for dnscrypt-proxy. dnsmasq listens on modules.dnscrypt-proxy.listenPort and forwards requests here";
        };
        runOutsidePort53 = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Allow dnsmasq to run on a port other than 53. Only enable this if you know what you're doing, as DNS clients expect port 53 by default.";
        };
        useStaleCache = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Serve expired cache entries when the upstream is unreachable (dnsmasq --use-stale-cache). Keeps popular names resolving instantly during WAN outages/bufferbloat instead of failing.";
        };
      };
      openFirewall = lib.mkEnableOption "opening the firewall port";
      dnscryptCache = lib.mkEnableOption "dnscrypt-proxy's own in-process DNS cache (a second cache layer in front of the WAN, on top of dnsmasq)";
      doh = lib.mkEnableOption "DNS over HTTPS support";
      dohPort = lib.mkOption {
        type = lib.types.port;
        default = 18053;
        description = "Port for the DNS over HTTPS server";
      };
      queryLog = {
        enable = lib.mkEnableOption "query logging";
        file = lib.mkOption {
          type = lib.types.str;
          default = "/run/dnscrypt-proxy/query.log";
          description = "Path to the query log file";
        };
      };
      nginx = {
        enable = lib.mkEnableOption "nginx DoH proxy";
        domain = lib.mkOption {
          type = lib.types.str;
          description = "Domain name for the DoH proxy";
          example = "dns.example.com";
        };
        forceSSL = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Redirect plain HTTP to HTTPS on the DoH virtualHost. Only disable this if TLS is terminated in front of nginx — plaintext DoH can be read or forged by any on-path observer, defeating the encryption this module exists to provide.";
        };
        enableACME = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Obtain the DoH virtualHost certificate via security.acme (requires security.acme.acceptTerms and a contact email). Set to false if you provision the certificate yourself; then attach useACMEHost or sslCertificate to the virtualHost.";
        };
      };
      serverNames =
        let
          # Pick a low-latency default upstream from the machine's timezone
          # purely to cut round-trip time; Cloudflare + Google stay as fixed
          # secondaries. Override this option to pin your own resolvers.
          timezone = if config.time.timeZone or null != null then config.time.timeZone else "UTC";
          defaultServer =
            if lib.hasPrefix "America/" timezone then
              "cs-brazil"
            else if lib.hasPrefix "Europe/" timezone then
              "cs-berlin"
            else
              "doh-crypto-sx";
        in
        lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            defaultServer
            "cloudflare"
            "google"
          ];
          description = "Names of the dnscrypt resolvers to use. Defaults to a server chosen by timezone with cloudflare and google as fallbacks.";
        };
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.dnsmasq.enable -> (cfg.listenPort == 53 || cfg.dnsmasq.runOutsidePort53);
        message = "dnsmasq must run on port 53 unless runOutsidePort53 is explicitly enabled. DNS clients expect port 53 by default.";
      }
    ];

    networking = lib.mkMerge [
      {
        nameservers = lib.mkDefault [ "127.0.0.1" ];
        resolvconf.useLocalResolver = lib.mkDefault true;
        dhcpcd.extraConfig = "nohook resolv.conf";
      }

      (lib.mkIf cfg.openFirewall {
        firewall.allowedUDPPorts = [ cfg.listenPort ];
      })
    ];

    systemd.services.dnscrypt-proxy = {
      description = "DNSCrypt-proxy client";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      # Regenerate networking.hosts into dnscrypt cloaking rules on every start.
      # Without this, encrypted upstream resolution bypasses /etc/hosts and your
      # local host overrides silently stop working.
      preStart = ''
        mkdir -p $RUNTIME_DIRECTORY
        chmod 755 $RUNTIME_DIRECTORY

        mkdir -p $STATE_DIRECTORY
        chmod 700 $STATE_DIRECTORY

        > $STATE_DIRECTORY/cloaking-rules.txt
        ${lib.concatStrings (
          lib.mapAttrsToList (
            ip: hostnames:
            lib.concatMapStrings (
              hostname: "echo '${hostname} ${ip}' >> $STATE_DIRECTORY/cloaking-rules.txt\n"
            ) hostnames
          ) config.networking.hosts
        )}
      '';
      serviceConfig = {
        RuntimeDirectory = "dnscrypt-proxy";
        RuntimeDirectoryMode = "0755";
        StateDirectory = "dnscrypt-proxy";
        StateDirectoryMode = "0700";
        DynamicUser = true;
        Restart = "always";
        RestartSec = "30s";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
      };
    };

    services.dnscrypt-proxy =
      let
        port = toString (if cfg.dnsmasq.enable then cfg.dnsmasq.internalPort else cfg.listenPort);
        listenAddresses = [
          "127.0.0.1:${port}"
        ]
        ++ (if config.networking.enableIPv6 then [ "[::1]:${port}" ] else [ ]);
      in
      {
        enable = true;
        settings =
          let
            dohAddresses = [
              "127.0.0.1:${toString cfg.dohPort}"
            ]
            ++ (if config.networking.enableIPv6 then [ "[::1]:${toString cfg.dohPort}" ] else [ ]);
          in
          {
            ipv6_servers = config.networking.enableIPv6;
            bootstrap_resolvers = [
              "1.1.1.1:53"
              "8.8.8.8:53"
              "9.9.9.9:53"
            ];
            sources.public-resolvers = {
              urls = [
                "https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md"
                "https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md"
              ];
              cache_file = "/var/lib/private/dnscrypt-proxy/public-resolvers.md";
              minisign_key = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3";
              refresh_delay = 72;
            };
            require_dnssec = false;
            cache = cfg.dnscryptCache;
            cloak_ttl = 60;
            listen_addresses = if cfg.doh then listenAddresses ++ dohAddresses else listenAddresses;
            cloaking_rules = "/var/lib/private/dnscrypt-proxy/cloaking-rules.txt";
            server_names = cfg.serverNames;
          }
          // (
            if cfg.queryLog.enable then
              {
                query_log = {
                  format = "tsv";
                  inherit (cfg.queryLog) file;
                };
              }
            else
              { }
          );
      };

    systemd.services.dnsmasq = lib.mkIf cfg.dnsmasq.enable {
      after = [
        "dnscrypt-proxy.service"
        "network-online.target"
      ];
      wants = [
        "dnscrypt-proxy.service"
        "network-online.target"
      ];
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    services = {
      dnsmasq = lib.mkIf cfg.dnsmasq.enable {
        enable = true;
        resolveLocalQueries = false;
        settings = {
          port = lib.mkForce cfg.listenPort;
          server = lib.mkDefault [ "127.0.0.1#${toString cfg.dnsmasq.internalPort}" ];
          no-resolv = lib.mkDefault true;
          no-negcache = lib.mkDefault true;
          cache-size = lib.mkDefault 4096;
          local-ttl = lib.mkDefault 30;
          bind-dynamic = lib.mkDefault true;
          address = [
            "/localhost/127.0.0.1"
            "/localhost/::1"
          ];
          interface = lib.mkIf ((builtins.length cfg.dnsmasq.bindInterfaces) > 0) cfg.dnsmasq.bindInterfaces;
        }
        // lib.optionalAttrs cfg.dnsmasq.useStaleCache {
          use-stale-cache = true;
        };
      };

      nginx = lib.mkIf (cfg.nginx.enable && cfg.doh) {
        virtualHosts.${cfg.nginx.domain} = {
          forceSSL = cfg.nginx.forceSSL;
          enableACME = cfg.nginx.enableACME;
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString cfg.dohPort}";
          };
        };
      };
    };
  };
}
