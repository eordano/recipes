{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.dnscrypt-proxy;

  stampsIn =
    file:
    let
      chunks = lib.drop 1 (lib.splitString "\n## " ("\n" + builtins.readFile file));
      entry =
        chunk:
        let
          chunkLines = lib.splitString "\n" chunk;
          name = lib.removeSuffix "\r" (lib.head chunkLines);
          stamps = lib.filter (l: lib.hasPrefix "sdns://" l) chunkLines;
        in
        lib.optionalAttrs (stamps != [ ]) {
          ${name} = lib.removeSuffix "\r" (lib.head stamps);
        };
    in
    lib.foldl' (acc: chunk: acc // (entry chunk)) { } chunks;

  knownStamps = lib.foldr (file: acc: acc // (stampsIn file)) { } cfg.resolverLists;
  pinResolvers = cfg.resolverLists != [ ];
  missingStamps = lib.filter (name: !(knownStamps ? ${name})) cfg.serverNames;
  firewallInterfaces = lib.filter (i: i != "lo") cfg.dnsmasq.bindInterfaces;
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
      openFirewall = lib.mkEnableOption "opening the firewall port (per interface in dnsmasq.bindInterfaces, excluding lo; on every interface when that list is empty)";
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
          description = "Redirect plain HTTP to HTTPS on the DoH virtualHost. Only disable this if TLS is terminated in front of nginx -- plaintext DoH can be read or forged by any on-path observer, defeating the encryption this module exists to provide.";
        };
        enableACME = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Obtain the DoH virtualHost certificate via security.acme (requires security.acme.acceptTerms and a contact email). Set to false if you provision the certificate yourself; then attach useACMEHost or sslCertificate to the virtualHost.";
        };
      };
      resolverLists = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        example = lib.literalExpression "[ inputs.dnscrypt-resolvers-official ]";
        description = "Pinned copies of DNSCrypt's public-resolvers.md. When non-empty, the stamp for each name in serverNames is extracted from these files at build time and written as a `static` server entry, and the runtime `sources.public-resolvers` block is dropped entirely -- dnscrypt-proxy then never fetches a resolver list over the network and keeps no list state under /var/lib. Lists are searched in order, so a second mirror can fill a gap in the first. Evaluation fails if a configured serverName appears in none of them. The tradeoff: a stamp freezes a resolver's address and public key, so a resolver that rotates keys needs these files re-pinned; leave this empty to keep the upstream refresh-and-minisign-verify behaviour.";
      };
      serverNames =
        let
          timezone = if config.time.timeZone or null != null then config.time.timeZone else "UTC";
          regionalServers =
            if lib.hasPrefix "America/" timezone then
              [ "dnscry.pt-miami-ipv4" ]
            else if lib.hasPrefix "Europe/" timezone then
              [ "cs-berlin" ]
            else
              [ "doh-crypto-sx" ];
        in
        lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = regionalServers ++ [
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
      {
        assertion = missingStamps == [ ];
        message = "modules.dnscrypt-proxy.serverNames: no sdns:// stamp for ${lib.concatStringsSep ", " missingStamps} in the pinned resolverLists. Either the name is misspelled or the resolver left the public list -- re-pin the lists, or clear resolverLists to go back to fetching them at runtime.";
      }
    ];

    networking = lib.mkMerge [
      {
        nameservers = lib.mkDefault [ "127.0.0.1" ];
        resolvconf.useLocalResolver = lib.mkDefault true;
        dhcpcd.extraConfig = "nohook resolv.conf";
      }

      (lib.mkIf (cfg.openFirewall && cfg.dnsmasq.bindInterfaces == [ ]) {
        firewall.allowedUDPPorts = [ cfg.listenPort ];
      })

      (lib.mkIf (cfg.openFirewall && firewallInterfaces != [ ]) {
        firewall.interfaces = lib.genAttrs firewallInterfaces (_: {
          allowedUDPPorts = [ cfg.listenPort ];
          allowedTCPPorts = [ cfg.listenPort ];
        });
      })
    ];

    systemd.services.dnscrypt-proxy = {
      description = "DNSCrypt-proxy client";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      stopIfChanged = false;
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
            require_dnssec = false;
            cache = cfg.dnscryptCache;
            cloak_ttl = 60;
            listen_addresses = if cfg.doh then listenAddresses ++ dohAddresses else listenAddresses;
            cloaking_rules = "/var/lib/private/dnscrypt-proxy/cloaking-rules.txt";
            server_names = cfg.serverNames;
          }
          // (
            if pinResolvers then
              {
                static = lib.genAttrs cfg.serverNames (name: {
                  stamp = knownStamps.${name};
                });
                sources = { };
              }
            else
              {
                sources.public-resolvers = {
                  urls = [
                    "https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md"
                    "https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md"
                  ];
                  cache_file = "/var/lib/private/dnscrypt-proxy/public-resolvers.md";
                  minisign_key = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3";
                  refresh_delay = 72;
                };
              }
          )
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
      stopIfChanged = false;
      reloadTriggers = [ config.environment.etc.hosts.source ];
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
