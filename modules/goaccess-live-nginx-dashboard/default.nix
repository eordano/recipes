{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.goaccessDashboard;

  goaccessWithGeoIP = pkgs.goaccess.overrideAttrs (oldAttrs: {
    configureFlags = (oldAttrs.configureFlags or [ ]) ++ [
      "--enable-geoip=mmdb"
      "--enable-utf8"
    ];
    buildInputs = (oldAttrs.buildInputs or [ ]) ++ [ pkgs.libmaxminddb ];
  });

  geoipUpdater = pkgs.writeShellScriptBin "goaccess-geoip-updater" ''
    set -eu
    GEOIP_DIR="${cfg.geoipDatabaseDir}"
    mkdir -p "$GEOIP_DIR"
    ${concatMapStringsSep "\n" (db: ''
      echo "Downloading ${db.name}..."
      ${pkgs.curl}/bin/curl -fL -o "$GEOIP_DIR/${db.name}" "${db.url}"
    '') cfg.geoipUpdater.databases}
    chmod 644 "$GEOIP_DIR"/*.mmdb
    echo "GeoIP databases updated."
  '';

  geoipDbFlags = concatMapStringsSep " " (
    db: "--geoip-database=${cfg.geoipDatabaseDir}/${db}"
  ) cfg.geoipDatabases;
in
{
  options.services.goaccessDashboard = {
    enable = mkEnableOption "GoAccess real-time nginx log dashboard";

    domain = mkOption {
      type = types.str;
      example = "stats.example.com";
      description = "Virtual host / FQDN the dashboard is served on.";
    };

    useACMEHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "example.com";
      description = ''
        Name of an ACME certificate (`security.acme.certs.<name>`) to reuse for
        TLS, or `null` to let this module request its own certificate for
        `domain` (in which case configure `security.acme` yourself).
      '';
    };

    accessLog = mkOption {
      type = types.path;
      default = "/var/log/nginx/access.log";
      description = "nginx access log GoAccess tails.";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/goaccess";
      description = "Where GoAccess keeps its on-disk DB and rendered HTML.";
    };

    user = mkOption {
      type = types.str;
      default = "goaccess";
      description = "System user the GoAccess process runs as.";
    };

    group = mkOption {
      type = types.str;
      default = "goaccess";
      description = "Primary group for the GoAccess user.";
    };

    uid = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "Optional fixed UID; `null` lets NixOS allocate one.";
    };

    gid = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "Optional fixed GID; `null` lets NixOS allocate one.";
    };

    allowedIPs = mkOption {
      type = types.listOf types.str;
      default = [
        "127.0.0.1"
        "::1"
        "10.0.0.0/8"
        "172.16.0.0/12"
        "192.168.0.0/16"
      ];
      example = [ "203.0.113.0/24" ];
      description = ''
        IPs / CIDR ranges allowed to reach both `/` and `/ws`. Everything else
        is denied. The dashboard leaks full request logs, so keep this tight.
      '';
    };

    htmlTitle = mkOption {
      type = types.str;
      default = "Web Server Analytics";
      description = "Title rendered at the top of the dashboard.";
    };

    logFormat = mkOption {
      type = types.str;
      default = ''%%h %%^[%%d:%%t %%^] "%%r" %%s %%b "%%R" "%%u" "%%v"'';
      description = ''
        GoAccess `--log-format` string. Every `%` MUST be doubled (`%%h`)
        because it is substituted into a systemd unit ExecStart. Named presets
        like `COMBINED` also work (no percent signs, nothing to escape).
      '';
    };

    dateFormat = mkOption {
      type = types.str;
      default = "%%d/%%b/%%Y";
      description = "GoAccess `--date-format` (percent signs doubled -- see logFormat).";
    };

    timeFormat = mkOption {
      type = types.str;
      default = "%%H:%%M:%%S";
      description = "GoAccess `--time-format` (percent signs doubled -- see logFormat).";
    };

    realTimePort = mkOption {
      type = types.port;
      default = 7890;
      description = ''
        Loopback TCP port GoAccess serves the WebSocket feed on. nginx reverse
        proxies `/ws` to it; it is never exposed directly.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open `realTimePort` in the host firewall. Usually unnecessary: nginx
        proxies to it over loopback, so leave this off.
      '';
    };

    geoipDatabaseDir = mkOption {
      type = types.str;
      default = "/var/lib/geoip-databases";
      description = "Directory holding the GeoLite2 `.mmdb` files.";
    };

    geoipDatabases = mkOption {
      type = types.listOf types.str;
      default = [
        "GeoLite2-City.mmdb"
        "GeoLite2-ASN.mmdb"
      ];
      description = ''
        `.mmdb` filenames (inside `geoipDatabaseDir`) passed to GoAccess as
        `--geoip-database`. GoAccess needs at least the City DB for the map.
      '';
    };

    geoipUpdater = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Install a systemd timer that downloads the GeoLite2 databases into
          `geoipDatabaseDir`. Off by default because the bundled default
          `databases` URLs point at a third-party GitHub mirror and nothing
          verifies the downloads' integrity -- enabling this is an explicit
          decision to trust that mirror. Preferred alternative: provision the
          `.mmdb` files yourself, e.g. with nixpkgs' `services.geoipupdate`
          and a free MaxMind license key. Note the GoAccess service refuses to
          start until the first database exists in `geoipDatabaseDir`.
        '';
      };

      interval = mkOption {
        type = types.str;
        default = "weekly";
        description = "systemd OnCalendar refresh interval for the databases.";
      };

      databases = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              name = mkOption {
                type = types.str;
                description = "Output filename written into geoipDatabaseDir.";
              };
              url = mkOption {
                type = types.str;
                description = "URL to download the .mmdb from.";
              };
            };
          }
        );
        default = [
          {
            name = "GeoLite2-City.mmdb";
            url = "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb";
          }
          {
            name = "GeoLite2-ASN.mmdb";
            url = "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb";
          }
        ];
        description = "GeoLite2 databases to fetch (name + download URL).";
      };
    };
  };

  config = mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      inherit (cfg) group;
      extraGroups = [ "nginx" ];
      description = "GoAccess web log analyzer";
    }
    // optionalAttrs (cfg.uid != null) { inherit (cfg) uid; };

    users.groups.${cfg.group} = optionalAttrs (cfg.gid != null) { inherit (cfg) gid; };

    users.users.nginx.extraGroups = [ cfg.group ];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/db 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/html 0750 ${cfg.user} ${cfg.group} - -"
    ]
    ++ optional cfg.geoipUpdater.enable "d ${cfg.geoipDatabaseDir} 0755 geoip geoip - -";

    systemd.services.goaccess = {
      description = "GoAccess real-time web log analyzer";
      after = [
        "network.target"
        "nginx.service"
      ]
      ++ optional cfg.geoipUpdater.enable "goaccess-geoip-updater.service";
      wants = optional cfg.geoipUpdater.enable "goaccess-geoip-updater.service";
      requires = [ "nginx.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;

        Environment = [
          "LANG=en_US.UTF-8"
          "LC_ALL=en_US.UTF-8"
        ];

        ExecStart = ''
          ${goaccessWithGeoIP}/bin/goaccess \
            ${cfg.accessLog} \
            --log-format='${cfg.logFormat}' \
            --date-format='${cfg.dateFormat}' \
            --time-format='${cfg.timeFormat}' \
            --real-time-html \
            --html-report-title="${cfg.htmlTitle}" \
            --ws-url=wss://${cfg.domain}/ws \
            --port=${toString cfg.realTimePort} \
            --addr=127.0.0.1 \
            ${geoipDbFlags} \
            --db-path=${cfg.dataDir}/db \
            --persist \
            --restore \
            -o ${cfg.dataDir}/html/index.html
        '';

        Restart = "always";
        RestartSec = "10s";

        PrivateTmp = true;
        ProtectHome = true;
        NoNewPrivileges = true;
        ReadWritePaths = [
          "${cfg.dataDir}/db"
          "${cfg.dataDir}/html"
        ];
        ReadOnlyPaths = [
          (dirOf cfg.accessLog)
          cfg.geoipDatabaseDir
        ];
      };

      preStart = ''
        if [ ! -f ${cfg.geoipDatabaseDir}/${head cfg.geoipDatabases} ]; then
          echo "GeoIP databases not found in ${cfg.geoipDatabaseDir}."
          echo "Enable services.goaccessDashboard.geoipUpdater or provision them yourself."
          exit 1
        fi
      '';
    };

    services.nginx.enable = true;
    services.nginx.virtualHosts.${cfg.domain} = {
      forceSSL = true;
      inherit (cfg) useACMEHost;
      enableACME = cfg.useACMEHost == null;

      root = "${cfg.dataDir}/html";

      locations."/" = {
        index = "index.html";
        extraConfig = ''
          ${concatMapStrings (ip: "allow ${ip};\n") cfg.allowedIPs}
          deny all;

          add_header X-Frame-Options "SAMEORIGIN" always;
          add_header X-Content-Type-Options "nosniff" always;
          add_header X-XSS-Protection "1; mode=block" always;
        '';
      };

      locations."/ws" = {
        proxyPass = "http://127.0.0.1:${toString cfg.realTimePort}";
        proxyWebsockets = true;
        extraConfig = ''
          ${concatMapStrings (ip: "allow ${ip};\n") cfg.allowedIPs}
          deny all;

          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;

          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection "upgrade";
          proxy_read_timeout 86400;
        '';
      };
    };

    networking.firewall.allowedTCPPorts = optional cfg.openFirewall cfg.realTimePort;

    environment.systemPackages = [ goaccessWithGeoIP ];

    users.users.geoip = mkIf cfg.geoipUpdater.enable {
      isSystemUser = true;
      group = "geoip";
      description = "GeoIP database updater";
    };
    users.groups.geoip = mkIf cfg.geoipUpdater.enable { };

    systemd.services.goaccess-geoip-updater = mkIf cfg.geoipUpdater.enable {
      description = "Download GeoLite2 databases for GoAccess";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${geoipUpdater}/bin/goaccess-geoip-updater";
        User = "geoip";
        Group = "geoip";
        PrivateTmp = true;
        ProtectHome = true;
        NoNewPrivileges = true;
        ReadWritePaths = [ cfg.geoipDatabaseDir ];
      };
    };

    systemd.timers.goaccess-geoip-updater = mkIf cfg.geoipUpdater.enable {
      description = "Refresh GeoLite2 databases periodically";
      wantedBy = [ "timers.target" ];
      partOf = [ "goaccess-geoip-updater.service" ];
      timerConfig = {
        OnCalendar = cfg.geoipUpdater.interval;
        OnBootSec = "5min";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };
}
