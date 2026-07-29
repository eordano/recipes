# GoAccess real-time HTML log dashboard, served over nginx + WebSocket,
# gated to an IP allow-list.
#
# A self-contained NixOS module. Import it and set at minimum:
#
#   services.goaccessDashboard = {
#     enable = true;
#     domain = "stats.example.com";
#     allowedIPs = [ "203.0.113.0/24" ];   # who may view the dashboard
#   };
#
# See README.md for the two traps this module exists to solve:
#   1. nixpkgs' goaccess ships WITHOUT MaxMind MMDB support -> overrideAttrs.
#   2. the log-format '%' signs must be doubled ('%%h') because the string
#      lands in a systemd ExecStart, where a bare '%' is a unit specifier.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.goaccessDashboard;

  # Trap 1: nixpkgs' goaccess is built without MaxMind (.mmdb) GeoIP support.
  # Rebuild it with the geoip flag rather than forking the package.
  goaccessWithGeoIP = pkgs.goaccess.overrideAttrs (oldAttrs: {
    configureFlags = (oldAttrs.configureFlags or [ ]) ++ [
      "--enable-geoip=mmdb"
      "--enable-utf8"
    ];
    buildInputs = (oldAttrs.buildInputs or [ ]) ++ [ pkgs.libmaxminddb ];
  });

  # Opt-in bundled GeoIP updater (geoipUpdater.enable = false by default).
  # Fetches GeoLite2 .mmdb files from a public third-party mirror, with no
  # integrity check -- see the option description and README before enabling.
  # The recommended path is provisioning geoipDatabaseDir yourself (e.g. via
  # nixpkgs' `services.geoipupdate`).
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
      # The dashboard exposes full visitor logs, so it MUST be gated. There is
      # no safe universal default -- set this to the operator/VPN/office ranges
      # that should see it. The default below is loopback + RFC1918 private
      # ranges as a fail-safe starting point; replace it.
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
      # Trap 2: every '%' is DOUBLED because this string is interpolated into a
      # systemd ExecStart, where a bare '%' is a unit specifier (%h = home dir,
      # etc.) and '%%' is systemd's literal-percent escape. This is NOT a Nix
      # thing -- '%' is not special in Nix strings.
      #
      # This default matches nginx's `combined` log format plus a trailing
      # vhost field (`$host` / '%v'). Adjust it to whatever your nginx
      # log_format actually emits, keeping every '%' doubled.
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
        type = types.listOf (types.submodule {
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
        });
        # Public mirror that republishes MaxMind's GeoLite2 files without an
        # account/license key. Trade-off: you trust the mirror's freshness and
        # integrity (no checksum verification here). Swap for MaxMind's own
        # authenticated downloads if you have a license key.
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
      group = cfg.group;
      # Needs to read nginx's access log and write HTML into a webroot nginx serves.
      extraGroups = [ "nginx" ];
      description = "GoAccess web log analyzer";
    } // optionalAttrs (cfg.uid != null) { uid = cfg.uid; };

    users.groups.${cfg.group} = optionalAttrs (cfg.gid != null) { gid = cfg.gid; };

    # nginx must be able to read the rendered HTML in the group-owned webroot.
    users.users.nginx.extraGroups = [ cfg.group ];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/db 0750 ${cfg.user} ${cfg.group} - -"
      # 0750, not 0755: the rendered index.html embeds full visitor logs (IPs,
      # URLs, referrers, user-agents). nginx serves it via its membership in
      # cfg.group, so no world bit is needed -- keep local accounts out.
      "d ${cfg.dataDir}/html 0750 ${cfg.user} ${cfg.group} - -"
    ]
    ++ optional cfg.geoipUpdater.enable "d ${cfg.geoipDatabaseDir} 0755 geoip geoip - -";

    systemd.services.goaccess = {
      description = "GoAccess real-time web log analyzer";
      after = [ "network.target" "nginx.service" ]
        ++ optional cfg.geoipUpdater.enable "goaccess-geoip-updater.service";
      wants = optional cfg.geoipUpdater.enable "goaccess-geoip-updater.service";
      requires = [ "nginx.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;

        # GoAccess parses timestamps against the C locale unless told otherwise.
        Environment = [
          "LANG=en_US.UTF-8"
          "LC_ALL=en_US.UTF-8"
        ];

        # NOTE: the '%%' in logFormat/dateFormat/timeFormat are systemd escapes
        # (see the option descriptions). systemd collapses each '%%' to a single
        # '%' before goaccess ever sees the argument.
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

      # Fail loudly rather than render a dashboard with an empty world map.
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
      useACMEHost = cfg.useACMEHost;
      enableACME = cfg.useACMEHost == null;

      root = "${cfg.dataDir}/html";

      # Static dashboard HTML. IP-gated: the page contains full visitor logs.
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

      # WebSocket feed that pushes live updates into the open dashboard.
      # Same allow-list, and the long read timeout keeps the socket alive.
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

    # --- Bundled GeoIP updater (optional) --------------------------------------
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
        # RemainAfterExit keeps the unit "active" after success so goaccess.service
        # (which Wants/After it) won't start until the databases exist at least once.
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
        # Jitter so a fleet doesn't hammer the mirror at the same minute.
        RandomizedDelaySec = "1h";
      };
    };
  };
}
