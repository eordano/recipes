# push-observability-receiver
#
# The RECEIVER half of a push-based observability stack. Remote hosts PUSH
# their journald logs and node metrics to this box over the Vector protocol
# (no scrape/pull of the agents). Vector fans logs into Loki and metrics into
# Prometheus (remote-write); Grafana reads both; nginx terminates TLS.
#
# The interesting part is everything Grafana CANNOT express through file
# provisioning, bolted on as oneshots ordered off grafana.service:
#   * admin password synced from a secret file, guarded by a sha256 flag-file
#     so it only re-runs when the secret actually changes;
#   * the home dashboard pinned by writing the DB `preferences` row directly;
#   * the Grafana secret_key generated once and pinned;
#   * a playlist provisioned over the HTTP API.
# Each of those polls for grafana.db / /api/health first, because Grafana
# creates them LAZILY on first start — the files simply do not exist until
# grafana has come up once.
#
# Self-referential Loki "context canceled" query-cancel spam is dropped twice
# (once in Vector, once via the unit's LogFilterPatterns) so the pipeline does
# not log about itself. GeoIP enrichment skips RFC1918 / CGNAT / loopback so
# only real external IPs hit the lookup.
#
# This file is deliberately self-contained: no external module imports, no
# secrets-management framework assumed. Point `adminPasswordFile` at a file
# produced by whatever secret system you use (agenix, sops-nix, a tmpfiles
# rule, …). Dashboards and alert rules are yours to supply.

{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkIf
    mkOption
    mkMerge
    mkDefault
    mkForce
    mkEnableOption
    types
    optional
    optionals
    optionalString
    optionalAttrs
    literalExpression
    ;

  cfg = config.services.push-observability-receiver;

  playlistPayload = pkgs.writeText "playlist.json" (
    builtins.toJSON {
      inherit (cfg.playlist) uid name interval;
      items = map (it: {
        type = "dashboard_by_uid";
        value = it.uid;
        title = it.title;
      }) cfg.playlist.items;
    }
  );

  havePlaylist = cfg.playlist.items != [ ];
  haveAdminPw = cfg.adminPasswordFile != null;
in
{
  options.services.push-observability-receiver = {
    enable = mkEnableOption "push-based Loki + Prometheus + Grafana receiver";

    domain = mkOption {
      type = types.str;
      description = "Domain name for the Grafana web interface (used as the nginx vhost).";
      example = "logs.example.com";
    };

    user = mkOption {
      type = types.str;
      default = "push-observability";
      description = "System user that owns the data directory.";
    };

    uid = mkOption {
      type = types.int;
      default = 3100;
      description = "Numeric uid for the service user (pin it so the persisted data keeps its owner across rebuilds).";
    };

    gid = mkOption {
      type = types.int;
      default = 3100;
      description = "Numeric gid for the service group.";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/push-observability";
      description = "Directory holding Loki chunks, Prometheus TSDB and the Grafana DB. Put it on persistent storage.";
    };

    enableNginx = mkOption {
      type = types.bool;
      default = true;
      description = "Front Grafana with an nginx reverse proxy on cfg.domain.";
    };

    acmeHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        If set, terminate TLS using the ACME certificate for this host
        (services.nginx `useACMEHost`). Leave null to serve plain HTTP
        (e.g. when TLS is terminated upstream).
      '';
      example = "logs.example.com";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "10.0.0.1";
      description = ''
        Interface/IP the two Vector push-ingest ports (logs + metrics) bind to.
        The vector protocol is UNAUTHENTICATED, so this defaults to loopback
        (127.0.0.1). Set it to a private/overlay address (VPN, WireGuard,
        Tailscale, …) that your agents can reach — never to 0.0.0.0 on a host
        with a public IP unless the ports are fronted by an authenticated
        tunnel/mTLS proxy, otherwise anyone can push forged logs and junk
        metrics into your stack.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open the host firewall for the two Vector ingest ports
        (`vectorPort`, `metricsPort`). Off by default: the vector protocol has
        no authentication, so exposing these ports is opt-in. Prefer reaching
        them over a private/overlay network (see `listenAddress`) and leaving
        this false. Only enable it when the ports are bound to a trusted
        interface or sit behind an authenticated tunnel/mTLS proxy.
      '';
    };

    vectorPort = mkOption {
      type = types.int;
      default = 4044;
      description = "TCP port Vector listens on for pushed LOGS (vector-protocol source).";
    };

    metricsPort = mkOption {
      type = types.int;
      default = 4045;
      description = "TCP port Vector listens on for pushed METRICS (vector-protocol source).";
    };

    lokiPort = mkOption {
      type = types.int;
      default = 3100;
      description = "Loki HTTP API port (loopback only).";
    };

    grafanaPort = mkOption {
      type = types.int;
      default = 3000;
      description = "Grafana HTTP port (loopback only; nginx proxies to it).";
    };

    prometheusPort = mkOption {
      type = types.int;
      default = 9090;
      description = "Prometheus HTTP + remote-write port (loopback only).";
    };

    nodeExporterPort = mkOption {
      type = types.int;
      default = 9100;
      description = "Port for the local node exporter that Prometheus scrapes.";
    };

    retentionPeriod = mkOption {
      type = types.str;
      default = "168h";
      description = "Loki log retention period.";
    };

    metricsRetentionPeriod = mkOption {
      type = types.str;
      default = "30d";
      description = "Prometheus metrics retention period.";
    };

    logLevel = mkOption {
      type = types.enum [
        "debug"
        "info"
        "warn"
        "error"
      ];
      default = "info";
      description = "Log level for Loki and Grafana.";
    };

    adminPasswordFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to a file containing the Grafana admin password, readable by the
        grafana user. When set, a oneshot syncs Grafana's admin password to
        this file on every activation — but ONLY when the file's sha256 changes
        (a flag file records the last-applied hash), so restarts don't reset the
        password every boot. Supply the file with agenix, sops-nix, a
        systemd.tmpfiles rule, or anything else. Null leaves Grafana's default
        admin/admin.
      '';
    };

    dashboardsDir = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Directory of Grafana dashboard *.json files to file-provision. Null
        skips dashboard provisioning entirely. A `home.json` in this directory
        is used as the default home dashboard when `homeDashboardUid` is set.
      '';
    };

    homeDashboardUid = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        UID of the dashboard to pin as the org home dashboard. Grafana cannot
        set this through file provisioning for the default org, so a oneshot
        writes the `preferences` row into grafana.db directly. Null skips it.
      '';
      example = "home";
    };

    playlist = {
      uid = mkOption {
        type = types.str;
        default = "rotation";
        description = "Stable UID for the provisioned playlist.";
      };
      name = mkOption {
        type = types.str;
        default = "Rotation";
        description = "Display name of the playlist.";
      };
      interval = mkOption {
        type = types.str;
        default = "30s";
        description = "How long each dashboard stays on screen.";
      };
      items = mkOption {
        default = [ ];
        description = ''
          Dashboards to rotate through, provisioned over the Grafana HTTP API
          (which requires the admin password — so this only runs when
          `adminPasswordFile` is also set). Empty list skips playlist
          provisioning.
        '';
        type = types.listOf (
          types.submodule {
            options = {
              uid = mkOption {
                type = types.str;
                description = "Dashboard UID.";
              };
              title = mkOption {
                type = types.str;
                description = "Human title (shown in the playlist editor).";
              };
            };
          }
        );
        example = literalExpression ''
          [
            { uid = "home";     title = "Home overview"; }
            { uid = "triage";   title = "Triage — USE"; }
          ]
        '';
      };
    };

    alerting = mkOption {
      type = types.nullOr types.attrs;
      default = null;
      description = ''
        Raw value for `services.grafana.provision.alerting`. Supply your own
        contact points / notification policies / alert rule groups here. Kept
        as a passthrough because alert rules are inherently site-specific (they
        name your hosts and services). Null disables provisioned alerting.
      '';
    };

    enableGeoIP = mkEnableOption ''
      GeoIP enrichment of incoming logs. When on, Vector augments any event
      carrying a `.remote_addr`, `.src_ip` or `.attacker_ip` field with
      `.geoip.{country_code,city,as_number,as_org}` plus a Loki `country`
      label. RFC1918 / CGNAT / loopback addresses are skipped so only real
      external IPs hit the lookup. You must provide the GeoLite2 databases
      (see geoipDatabaseDir) — this module does not download them
    '';

    geoipDatabaseDir = mkOption {
      type = types.str;
      default = "/var/lib/GeoIP";
      description = ''
        Directory containing GeoLite2-City.mmdb and GeoLite2-ASN.mmdb, used
        when enableGeoIP is on. Populate it with your own updater (e.g. the
        `geoipupdate` package on a timer).
      '';
    };

    geoipUpdaterUnit = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Optional systemd unit name for a GeoIP-database updater. When set,
        Vector is ordered after it (after/wants) so the mmdb files exist before
        Vector opens them. Null if you refresh the databases out of band.
      '';
      example = "geoipupdate.service";
    };

    udmSyslog = {
      enable = mkEnableOption "UDP syslog ingest + iptables-style firewall-log parsing (e.g. from a router/gateway)";

      port = mkOption {
        type = types.int;
        default = 5514;
        description = "UDP port for Vector's syslog listener.";
      };

      bindAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = ''
          Interface/IP to bind the syslog listener on. Bind it to a private/LAN
          address so the UDP port is not reachable from the public internet or
          an overlay network.
        '';
      };

      hostLabel = mkOption {
        type = types.str;
        default = "gateway";
        description = "Value for the Loki `host` label on syslog events.";
      };

      siteLabel = mkOption {
        type = types.str;
        default = "site";
        description = "Value stashed in the `.site` field on syslog events.";
      };
    };

    extraScrapeJobs = mkOption {
      type = types.listOf types.attrs;
      default = [ ];
      description = ''
        Additional Prometheus `scrape_configs` entries. Use for sources that
        can't push via Vector remote-write — exporters on hosts you don't
        control, or anything behind a reverse proxy. Attach a `host` label in
        `static_configs[].labels` so dashboards' `{host=~"$host"}` filter picks
        it up.
      '';
      example = literalExpression ''
        [{
          job_name = "ups";
          scheme = "https";
          static_configs = [{
            targets = [ "ups.example.com" ];
            labels = { host = "your-host"; job = "ups"; };
          }];
        }]
      '';
    };

    smtp = {
      enabled = mkOption {
        type = types.bool;
        default = false;
        description = "Enable SMTP for Grafana email notifications.";
      };
      host = mkOption {
        type = types.str;
        default = "";
        example = "smtp.example.com:587";
        description = "SMTP server host:port.";
      };
      user = mkOption {
        type = types.str;
        default = "";
        description = "SMTP username.";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          EnvironmentFile providing SMTP_PASSWORD to the grafana unit. The
          Grafana password field references ''${SMTP_PASSWORD}.
        '';
      };
      fromAddress = mkOption {
        type = types.str;
        default = "";
        example = "grafana@example.com";
        description = "Envelope-from address.";
      };
      fromName = mkOption {
        type = types.str;
        default = "Grafana";
        description = "Display name for outgoing mail.";
      };
      startTLS = mkOption {
        type = types.enum [
          "OpportunisticStartTLS"
          "MandatoryStartTLS"
          "NoStartTLS"
        ];
        default = "OpportunisticStartTLS";
        description = "StartTLS policy for SMTP.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf cfg.enableNginx {
      services.nginx.enable = true;
      services.nginx.virtualHosts.${cfg.domain} = {
        forceSSL = cfg.acmeHost != null;
        useACMEHost = cfg.acmeHost;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.grafanaPort}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_buffering off;
            proxy_read_timeout 1d;
            proxy_send_timeout 1d;
          '';
        };
      };
    })
    {
      assertions = [
        {
          assertion = cfg.domain != "";
          message = "services.push-observability-receiver: domain must be set when enabled";
        }
      ];

      # Fronting Grafana with nginx while leaving adminPasswordFile unset serves
      # the login on cfg.domain with Grafana's well-known admin/admin default
      # until it is changed by hand — a full dashboard/datasource takeover if a
      # bot reaches it first. Warn loudly so an adopter can't do this silently.
      warnings = optional (cfg.enableNginx && cfg.adminPasswordFile == null) ''
        services.push-observability-receiver: Grafana is exposed via nginx on
        ${cfg.domain} but adminPasswordFile is unset, so the login keeps
        Grafana's default admin/admin credentials until changed manually. Set
        adminPasswordFile (agenix/sops/tmpfiles) before exposing this box, or
        set enableNginx = false if you front Grafana yourself.
      '';

      users.users.${cfg.user} = {
        uid = cfg.uid;
        isSystemUser = true;
        group = cfg.user;
        description = "push-observability receiver service user";
        home = cfg.dataDir;
      };

      users.groups.${cfg.user}.gid = cfg.gid;

      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0755 ${toString cfg.uid} ${toString cfg.gid} - -"
        "d ${cfg.dataDir}/loki 0755 loki loki - -"
        "d ${cfg.dataDir}/loki/chunks 0755 loki loki - -"
        "d ${cfg.dataDir}/loki/rules 0755 loki loki - -"
        "d ${cfg.dataDir}/loki/boltdb-compactor 0755 loki loki - -"
        "d ${cfg.dataDir}/grafana 0755 grafana grafana - -"
        "d ${cfg.dataDir}/grafana/plugins 0755 grafana grafana - -"
      ];

      # --- Grafana secret_key: generate once, pin it -----------------------
      # Grafana derives at-rest encryption from secret_key. Generate a stable
      # one before grafana starts (default is a shipped constant).
      systemd.services.grafana-secret-key = {
        description = "Generate Grafana secret key";
        wantedBy = [ "grafana.service" ];
        before = [ "grafana.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # dataDir/grafana is already tmpfiles-owned grafana:grafana, so a file
          # this unit creates there is already correctly owned -- no root/chown
          # needed, matching the sibling grafana-admin-password-reset unit below.
          User = "grafana";
          Group = "grafana";
        };
        script = ''
          KEY_FILE="${cfg.dataDir}/grafana/secret_key"
          if [ ! -f "$KEY_FILE" ]; then
            ${pkgs.openssl}/bin/openssl rand -base64 32 > "$KEY_FILE"
            chmod 0400 "$KEY_FILE"
          fi
        '';
      };

      # --- Pin the home dashboard by writing the DB row --------------------
      # Grafana can't set the org home dashboard via file provisioning, so we
      # write the `preferences` row directly. grafana.db is created LAZILY on
      # first start, so poll for it first, then retry the write under a busy
      # timeout (grafana may hold the sqlite lock at boot).
      systemd.services.grafana-home-preference = mkIf (cfg.homeDashboardUid != null) {
        description = "Pin the Grafana home dashboard";
        after = [ "grafana.service" ];
        wantedBy = [ "grafana.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # grafana.db lives under dataDir/grafana, already owned by grafana:grafana
          # (tmpfiles rule above), so the sqlite write needs no elevated privilege.
          User = "grafana";
          Group = "grafana";
        };
        script =
          let
            sql = pkgs.writeText "grafana-home-pref.sql" ''
              PRAGMA busy_timeout = 30000;
              INSERT OR REPLACE INTO preferences
                (id, org_id, user_id, version, home_dashboard_id,
                 timezone, theme, created, updated,
                 team_id, week_start, json_data, home_dashboard_uid)
                VALUES
                ((SELECT id FROM preferences WHERE org_id=1 AND user_id=0 AND team_id IS NULL),
                 1, 0, 0, 0,
                 ''', ''', datetime('now'), datetime('now'),
                 NULL, NULL, NULL, '${cfg.homeDashboardUid}');
            '';
          in
          ''
            DB="${cfg.dataDir}/grafana/data/grafana.db"
            for i in 1 2 3 4 5 6 7 8 9 10; do
              [ -f "$DB" ] && break
              sleep 1
            done
            for i in 1 2 3 4 5 6 7 8 9 10; do
              ${pkgs.sqlite}/bin/sqlite3 "$DB" < ${sql} && exit 0
              sleep 3
            done
            exit 1
          '';
      };

      # --- Sync admin password from a secret file (idempotent) -------------
      # Reset only when the secret's sha256 differs from the last applied hash
      # (recorded in a flag file). Without the guard this would reset the
      # password on every activation, fighting any UI-side change and churning
      # the DB. Polls for grafana.db because the reset CLI needs it to exist.
      systemd.services.grafana-admin-password-reset = mkIf haveAdminPw {
        description = "Sync Grafana admin password from a secret file";
        after = [ "grafana.service" ];
        requires = [ "grafana.service" ];
        wantedBy = [ "grafana.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "grafana";
          Group = "grafana";
          # PID1 (root) reads the secret and hands it over at
          # $CREDENTIALS_DIRECTORY/admin-pw, so the file itself never has to be
          # readable by the service user. Same idiom as grafana-playlist below.
          LoadCredential = "admin-pw:${cfg.adminPasswordFile}";
        };
        path = [ pkgs.coreutils ];
        script = ''
          set -euo pipefail
          SECRET="$CREDENTIALS_DIRECTORY/admin-pw"
          FLAG="${cfg.dataDir}/grafana/.admin-pw-secret-hash"

          DB="${cfg.dataDir}/grafana/data/grafana.db"
          for i in $(seq 1 30); do
            [ -f "$DB" ] && break
            sleep 1
          done

          WANT=$(sha256sum "$SECRET" | cut -d' ' -f1)
          HAVE=""
          [ -f "$FLAG" ] && HAVE=$(cat "$FLAG")

          if [ "$WANT" = "$HAVE" ]; then
            echo "admin password already in sync with secret ($WANT)"
            exit 0
          fi

          echo "syncing admin password from secret file"
          ${config.services.grafana.package}/bin/grafana cli \
            --homepath ${cfg.dataDir}/grafana \
            admin reset-admin-password "$(cat "$SECRET")"
          echo "$WANT" > "$FLAG"
        '';
      };

      # --- Provision a playlist over the HTTP API --------------------------
      # Playlists aren't file-provisionable, so POST/PUT over the API. Needs the
      # admin password (hence gated on adminPasswordFile) and a healthy Grafana,
      # so poll /api/health first. Probe the playlist by uid to decide create
      # vs update — the API has no idempotent upsert.
      systemd.services.grafana-playlist = mkIf (havePlaylist && haveAdminPw) {
        description = "Provision the rotation playlist via Grafana API";
        after = [
          "grafana.service"
          "grafana-admin-password-reset.service"
        ];
        requires = [
          "grafana.service"
          "grafana-admin-password-reset.service"
        ];
        wantedBy = [ "grafana.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "grafana";
          Group = "grafana";
          LoadCredential = "admin-pw:${cfg.adminPasswordFile}";
        };
        path = [
          pkgs.curl
          pkgs.coreutils
        ];
        script = ''
          set -euo pipefail
          BASE="http://127.0.0.1:${toString cfg.grafanaPort}"
          ADMIN_PW=$(cat "$CREDENTIALS_DIRECTORY/admin-pw")

          for i in $(seq 1 60); do
            if curl -fsS -o /dev/null "$BASE/api/health"; then break; fi
            sleep 2
          done

          auth=(--silent --show-error -u "admin:$ADMIN_PW")

          code=$(curl "''${auth[@]}" -o /dev/null -w '%{http_code}' \
            "$BASE/api/playlists/${cfg.playlist.uid}" || true)

          if [ "$code" = "200" ]; then
            echo "updating existing playlist ${cfg.playlist.uid}"
            curl "''${auth[@]}" --fail-with-body -X PUT \
              -H 'Content-Type: application/json' \
              --data '@${playlistPayload}' \
              "$BASE/api/playlists/${cfg.playlist.uid}" >/dev/null
          else
            echo "creating playlist ${cfg.playlist.uid} (probe returned $code)"
            curl "''${auth[@]}" --fail-with-body -X POST \
              -H 'Content-Type: application/json' \
              --data '@${playlistPayload}' \
              "$BASE/api/playlists" >/dev/null
          fi

          echo "verify:"
          curl "''${auth[@]}" --fail-with-body \
            "$BASE/api/playlists/${cfg.playlist.uid}"
          echo
        '';
      };

      # --- Vector: the push ingest + fan-out -------------------------------
      services.vector = {
        enable = true;
        package = mkDefault pkgs.vector;
        journaldAccess = true;

        settings = mkMerge [
          {
            enrichment_tables = mkIf cfg.enableGeoIP {
              geoip_table = {
                type = "geoip";
                path = "${cfg.geoipDatabaseDir}/GeoLite2-City.mmdb";
              };
              asn_table = {
                type = "geoip";
                path = "${cfg.geoipDatabaseDir}/GeoLite2-ASN.mmdb";
              };
            };

            # Remote hosts PUSH here over the vector protocol — no scrape.
            sources.agent_logs = {
              type = "vector";
              address = "${cfg.listenAddress}:${toString cfg.vectorPort}";
              version = "2";
              acknowledgements.enabled = false;
            };

            sources.agent_metrics = {
              type = "vector";
              address = "${cfg.listenAddress}:${toString cfg.metricsPort}";
              version = "2";
              acknowledgements.enabled = false;
            };

            # This box's own journal, minus vector itself (avoid self-feedback).
            sources.central_journal = {
              type = "journald";
              current_boot_only = true;
              exclude_units = [ "vector.service" ];
            };

            # Drop Loki's own query-cancel spam in the pipeline (belt); the
            # unit's LogFilterPatterns below is the suspenders.
            transforms.drop_loki_query_cancel_noise = {
              type = "filter";
              inputs = [ "central_journal" ];
              condition = {
                type = "vrl";
                source = ''
                  unit = string(._SYSTEMD_UNIT) ?? ""
                  msg = string(.message) ?? ""
                  !(unit == "loki.service" && contains(msg, "context canceled"))
                '';
              };
            };

            transforms.process_logs = {
              type = "remap";
              inputs = [
                "agent_logs"
                "drop_loki_query_cancel_noise"
              ]
              ++ optional cfg.udmSyslog.enable "udm_parse";
              source = ''
                if !exists(.labels) {
                  .labels = {}
                }

                if !exists(.labels.host) {
                  .labels.host = "${config.networking.hostName}"
                  if exists(.host) {
                    .labels.host = .host
                  }
                }

                if !exists(.labels.unit) {
                  if exists(._SYSTEMD_UNIT) {
                    unit_raw = string!(._SYSTEMD_UNIT)
                    .labels.unit = replace(unit_raw, r'@[^.]+', "@")
                  } else if exists(._SYSTEMD_USER_UNIT) {
                    unit_raw = string!(._SYSTEMD_USER_UNIT)
                    .labels.unit = "user:" + replace(unit_raw, r'@[^.]+', "@")
                  } else {
                    .labels.unit = "none"
                  }
                }

                if !exists(.labels.source) {
                  .labels.source = "journald"
                }

                if !exists(.labels.vhost) {
                  .labels.vhost = "none"
                }
                if !exists(.labels.country) {
                  .labels.country = "unknown"
                }
                if !exists(.labels.udm_kind) {
                  .labels.udm_kind = "none"
                }

                if !exists(.labels.severity) {
                  if exists(.PRIORITY) {
                    p = to_int(.PRIORITY) ?? 6
                    if p <= 3 {
                      .labels.severity = "error"
                    } else if p == 4 {
                      .labels.severity = "warn"
                    } else if p <= 6 {
                      .labels.severity = "info"
                    } else {
                      .labels.severity = "debug"
                    }
                  } else {
                    .labels.severity = "info"
                  }
                }

                # Container units log severity in their message body, not in
                # PRIORITY — sniff common formats so dashboards can filter.
                if exists(.labels.unit) && exists(.message) {
                  unit_str = string!(.labels.unit)
                  if starts_with(unit_str, "podman-") ||
                     unit_str == "docker.service" {
                    msg = string!(.message)
                    if contains(msg, "[CRITICAL]") || contains(msg, "[FATAL]") ||
                       contains(msg, "[ERROR]") || contains(msg, " ERROR ") ||
                       contains(msg, " - ERROR - ") || contains(msg, " - FATAL - ") ||
                       contains(msg, " - CRITICAL - ") ||
                       contains(msg, "CRITICAL:") || contains(msg, "ERROR:") ||
                       contains(msg, "\terror\t") || contains(msg, "\tfatal\t") ||
                       contains(msg, "Traceback (most recent call last)") {
                      .labels.severity = "error"
                    } else if contains(msg, "[WARNING]") || contains(msg, "[WARN]") ||
                              contains(msg, " - WARNING - ") || contains(msg, " - WARN - ") ||
                              contains(msg, "WARNING:") || contains(msg, " WARN ") ||
                              contains(msg, "\twarn\t") || contains(msg, "\twarning\t") {
                      .labels.severity = "warn"
                    } else if contains(msg, "[DEBUG]") || contains(msg, " - DEBUG - ") ||
                              contains(msg, "DEBUG:") || contains(msg, "\tdebug\t") {
                      .labels.severity = "debug"
                    } else if contains(msg, "[INFO]") || contains(msg, " - INFO - ") ||
                              contains(msg, "INFO:") || contains(msg, "\tinfo\t") {
                      .labels.severity = "info"
                    } else {
                      .labels.severity = "info"
                    }
                  }
                }
              ''
              + optionalString cfg.enableGeoIP ''

                if exists(.labels.unit) && string!(.labels.unit) == "sshd.service" && exists(.message) {
                  msg = string!(.message)
                  m = parse_regex(msg, r'(?:from|by(?: authenticating user \S+)?) (?P<ip>\d+\.\d+\.\d+\.\d+)') ?? null
                  if m != null {
                    .attacker_ip = m.ip
                  }
                }

                ip_candidate = null
                if exists(.remote_addr) {
                  ip_candidate = string!(.remote_addr)
                } else if exists(.src_ip) {
                  ip_candidate = string!(.src_ip)
                } else if exists(.attacker_ip) {
                  ip_candidate = string!(.attacker_ip)
                }

                if ip_candidate != null {
                  ip = string!(ip_candidate)
                  # Skip private / shared / loopback / link-local — only real
                  # external IPs are worth a GeoIP lookup, and internal ones
                  # just miss. Test CIDR containment, never string prefixes:
                  # "172.2" also matches public 172.2.x.x and 172.2xx.x.x, and
                  # "100.64." covers only a /16 of the 100.64.0.0/10 range.
                  # ?? false keeps a non-IP candidate from aborting the program;
                  # it then falls through to a lookup that simply misses.
                  is_private = (ip_cidr_contains("10.0.0.0/8", ip) ?? false) ||
                               (ip_cidr_contains("172.16.0.0/12", ip) ?? false) ||
                               (ip_cidr_contains("192.168.0.0/16", ip) ?? false) ||
                               (ip_cidr_contains("127.0.0.0/8", ip) ?? false) ||
                               (ip_cidr_contains("100.64.0.0/10", ip) ?? false) ||
                               (ip_cidr_contains("169.254.0.0/16", ip) ?? false) ||
                               (ip_cidr_contains("::1/128", ip) ?? false) ||
                               (ip_cidr_contains("fc00::/7", ip) ?? false) ||
                               (ip_cidr_contains("fe80::/10", ip) ?? false)
                  if !is_private {
                    geo, err = get_enrichment_table_record("geoip_table", { "ip": ip })
                    if err == null && geo != null {
                      .geoip = {}
                      if exists(geo.country_code) && geo.country_code != null {
                        cc = downcase(string!(geo.country_code))
                        .geoip.country_code = cc
                        .labels.country = cc
                      }
                      if exists(geo.city_name) && geo.city_name != null {
                        .geoip.city = string!(geo.city_name)
                      }
                    }
                    asn, asn_err = get_enrichment_table_record("asn_table", { "ip": ip })
                    if asn_err == null && asn != null {
                      if exists(asn.autonomous_system_number) {
                        .geoip.as_number = asn.autonomous_system_number
                      }
                      if exists(asn.autonomous_system_organization) && asn.autonomous_system_organization != null {
                        .geoip.as_org = string!(asn.autonomous_system_organization)
                      }
                    }
                  }
                }
              '';
            };

            sinks.loki = {
              type = "loki";
              inputs = [ "process_logs" ];
              endpoint = "http://127.0.0.1:${toString cfg.lokiPort}";
              encoding.codec = "json";
              # Vector 0.57 rejects label templates that are bare event-field
              # references (`{{labels.host}}`) with no static prefix; these are
              # Loki labels, not file paths, so opt out of the confinement check.
              dangerously_allow_unconfined_template_resolution = true;
              labels = {
                host = "{{labels.host}}";
                unit = "{{labels.unit}}";
                source = "{{labels.source}}";
                vhost = "{{labels.vhost}}";
                country = "{{labels.country}}";
                severity = "{{labels.severity}}";
                udm_kind = "{{labels.udm_kind}}";
              };
              remove_label_fields = true;
            };

            sinks.prometheus = {
              type = "prometheus_remote_write";
              inputs = [ "agent_metrics" ];
              endpoint = "http://127.0.0.1:${toString cfg.prometheusPort}/api/v1/write";
              healthcheck.enabled = false;
              request = {
                retry_initial_backoff_secs = 2;
                retry_max_duration_secs = 600;
                timeout_secs = 60;
              };
            };
          }
          (mkIf cfg.udmSyslog.enable {
            sources.udm_syslog = {
              type = "syslog";
              mode = "udp";
              address = "${cfg.udmSyslog.bindAddress}:${toString cfg.udmSyslog.port}";
            };

            transforms.udm_parse = {
              type = "remap";
              inputs = [ "udm_syslog" ];
              source = ''
                if !exists(.labels) { .labels = {} }
                .labels.source = "udm"
                .labels.host = "${cfg.udmSyslog.hostLabel}"
                .labels.unit = "none"
                .labels.vhost = "none"
                .labels.country = "unknown"
                sev = if exists(.severity) { string!(.severity) } else { "info" }
                if sev == "err" || sev == "error" || sev == "crit" ||
                   sev == "alert" || sev == "emerg" {
                  .labels.severity = "error"
                } else if sev == "warning" || sev == "warn" || sev == "notice" {
                  .labels.severity = "warn"
                } else if sev == "debug" {
                  .labels.severity = "debug"
                } else {
                  .labels.severity = "info"
                }

                msg = if exists(.message) { string!(.message) } else { "" }
                # iptables/netfilter firewall log line — pull structured fields.
                if match(msg, r'SRC=[\d\.]+.*DST=[\d\.]+.*PROTO=') {
                  .labels.udm_kind = "firewall"
                  fw = parse_regex(msg, r'(?:DESCR="(?P<rule>[^"]*)")?.*?IN=(?P<in_if>\S*)\s+OUT=(?P<out_if>\S*).*?SRC=(?P<src_ip>\S+)\s+DST=(?P<dst_ip>\S+)(?:.*?PROTO=(?P<proto>\S+))?(?:.*?SPT=(?P<src_port>\d+))?(?:.*?DPT=(?P<dst_port>\d+))?') ?? null
                  if fw != null {
                    if exists(fw.rule) { .rule = fw.rule }
                    if exists(fw.in_if) { .in_if = fw.in_if }
                    if exists(fw.out_if) { .out_if = fw.out_if }
                    if exists(fw.src_ip) { .src_ip = fw.src_ip }
                    if exists(fw.dst_ip) { .dst_ip = fw.dst_ip }
                    if exists(fw.proto) { .proto = fw.proto }
                    if exists(fw.src_port) { .src_port = fw.src_port }
                    if exists(fw.dst_port) { .dst_port = fw.dst_port }
                  }
                } else if contains(msg, "dnsmasq-dhcp") {
                  .labels.udm_kind = "dhcp"
                } else if contains(msg, "dnsmasq[") {
                  .labels.udm_kind = "dns"
                } else if contains(msg, "ubios-udapi-server") ||
                          contains(msg, "ubios-") {
                  .labels.udm_kind = "controller"
                } else {
                  .labels.udm_kind = "other"
                }

                .site = "${cfg.udmSyslog.siteLabel}"

                # Accepted-traffic firewall lines aren't warnings; downgrade.
                if .labels.udm_kind == "firewall" && .labels.severity == "warn" {
                  .labels.severity = "info"
                }
              '';
            };
          })
        ];
      };

      networking.firewall.allowedUDPPorts = optional cfg.udmSyslog.enable cfg.udmSyslog.port;

      systemd.services = {
        vector = {
          serviceConfig = {
            CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
            AmbientCapabilities = [ "CAP_DAC_READ_SEARCH" ];
            ReadWritePaths = [ "/var/lib/vector" ];
          };
          after = [
            "prometheus.service"
            "loki.service"
          ]
          ++ optional (cfg.enableGeoIP && cfg.geoipUpdaterUnit != null) cfg.geoipUpdaterUnit;
          wants = [
            "prometheus.service"
            "loki.service"
          ]
          ++ optional (cfg.enableGeoIP && cfg.geoipUpdaterUnit != null) cfg.geoipUpdaterUnit;
        };

        grafana = {
          after = [
            "prometheus.service"
            "loki.service"
          ];
          wants = [
            "prometheus.service"
            "loki.service"
          ];
        };
      };

      # --- Loki: single-binary filesystem store ----------------------------
      services.loki = {
        enable = true;
        package = pkgs.grafana-loki;
        dataDir = "${cfg.dataDir}/loki";
        configuration = {
          auth_enabled = false;
          server = {
            http_listen_port = cfg.lokiPort;
            log_level = cfg.logLevel;
            grpc_server_max_recv_msg_size = 16777216;
            grpc_server_max_send_msg_size = 16777216;
          };
          storage_config.filesystem.directory = "${cfg.dataDir}/loki/chunks";
          common = {
            path_prefix = "${cfg.dataDir}/loki";
            storage.filesystem = {
              chunks_directory = "${cfg.dataDir}/loki/chunks";
              rules_directory = "${cfg.dataDir}/loki/rules";
            };
            replication_factor = 1;
            ring.kvstore.store = "inmemory";
          };
          schema_config.configs = [
            {
              from = "2023-01-01";
              store = "tsdb";
              object_store = "filesystem";
              schema = "v13";
              index.prefix = "index_";
              index.period = "24h";
            }
          ];
          compactor.working_directory = "${cfg.dataDir}/loki/boltdb-compactor";
          limits_config = {
            retention_period = cfg.retentionPeriod;
            reject_old_samples = false;
            reject_old_samples_max_age = "8760h";
            ingestion_rate_mb = 10;
            ingestion_burst_size_mb = 20;
            per_stream_rate_limit = "5MB";
            per_stream_rate_limit_burst = "10MB";
          };
        };
      };

      # Suspenders for Loki's self-referential query-cancel chatter.
      systemd.services.loki.serviceConfig.LogFilterPatterns = [
        "~msg=\"error processing requests from scheduler\""
        "~msg=\"error fetching chunks\" err=\"context canceled\""
        "~msg=\"failed downloading chunks\" err=\"context canceled\""
        "~msg=\"error notifying scheduler about finished query\" err=EOF"
      ];

      services.prometheus.exporters.node = {
        enable = true;
        port = cfg.nodeExporterPort;
        enabledCollectors = [
          "systemd"
          "processes"
          "filesystem"
          "meminfo"
          "cpu"
          "loadavg"
          "netdev"
          "diskstats"
          "zfs"
        ];
        disabledCollectors = [ "powersupplyclass" ];
      };

      services.prometheus = {
        enable = true;
        port = cfg.prometheusPort;
        retentionTime = cfg.metricsRetentionPeriod;

        configText = builtins.toJSON {
          global = {
            scrape_interval = "30s";
            evaluation_interval = "30s";
          };
          scrape_configs = [
            {
              job_name = "prometheus";
              static_configs = [
                { targets = [ "localhost:${toString cfg.prometheusPort}" ]; }
              ];
            }
            {
              job_name = "node";
              static_configs = [
                {
                  targets = [ "localhost:${toString cfg.nodeExporterPort}" ];
                  labels.host = config.networking.hostName;
                }
              ];
            }
          ]
          ++ cfg.extraScrapeJobs;
          # Pushed metrics can arrive slightly out of order across agents.
          storage.tsdb.out_of_order_time_window = "10m";
        };

        # Accept Vector's remote-write.
        extraFlags = [ "--web.enable-remote-write-receiver" ];
      };

      systemd.services.grafana.serviceConfig = {
        # dataDir lives on persistent storage, not a StateDirectory.
        StateDirectory = mkForce "";
      }
      // optionalAttrs (cfg.smtp.enabled && cfg.smtp.passwordFile != null) {
        EnvironmentFile = cfg.smtp.passwordFile;
      };

      services.grafana = {
        enable = true;
        dataDir = "${cfg.dataDir}/grafana";
        provision = {
          datasources.settings.datasources = [
            {
              name = "Loki";
              type = "loki";
              uid = "loki";
              url = "http://localhost:${toString cfg.lokiPort}";
              access = "proxy";
              isDefault = true;
            }
            {
              name = "Prometheus";
              type = "prometheus";
              uid = "prometheus";
              url = "http://localhost:${toString cfg.prometheusPort}";
              access = "proxy";
            }
          ];

          dashboards.settings = optionalAttrs (cfg.dashboardsDir != null) {
            providers = [
              {
                name = "default";
                type = "file";
                folder = "System";
                options = {
                  path = cfg.dashboardsDir;
                  foldersFromFilesStructure = true;
                };
              }
            ];
          };
        }
        # `provision.alerting` is a submodule, not a nullable option: assigning it
        # `mkIf false null` still surfaces the null and fails type-checking. Omit
        # the key entirely when no alerting config is supplied.
        // optionalAttrs (cfg.alerting != null) {
          alerting = cfg.alerting;
        };

        settings = {
          server = {
            domain = cfg.domain;
            http_port = cfg.grafanaPort;
            protocol = "http";
            http_addr = "127.0.0.1";
          };
          analytics = {
            enabled = false;
            reporting_enabled = false;
            check_for_updates = false;
            check_for_plugin_updates = false;
          };
          security.secret_key = "$__file{${cfg.dataDir}/grafana/secret_key}";
          log = {
            mode = "console";
            level = cfg.logLevel;
          };
          users = {
            viewers_can_edit = true;
          }
          // optionalAttrs (cfg.dashboardsDir != null && cfg.homeDashboardUid != null) {
            default_home_dashboard_path = "${cfg.dashboardsDir}/home.json";
            home_page = "/d/${cfg.homeDashboardUid}";
          };
          plugins.disable_plugins = "grafana-oncall-app,grafana-irm-app";
        }
        // optionalAttrs cfg.smtp.enabled {
          smtp = {
            enabled = true;
            host = cfg.smtp.host;
            user = cfg.smtp.user;
            password = if cfg.smtp.passwordFile != null then "\${SMTP_PASSWORD}" else "";
            from_address = cfg.smtp.fromAddress;
            from_name = cfg.smtp.fromName;
            starttls_policy = cfg.smtp.startTLS;
          };
        };
      };

      networking.firewall.allowedTCPPorts =
        optionals cfg.openFirewall [
          cfg.vectorPort
          cfg.metricsPort
        ]
        ++ optional cfg.enableNginx 80
        ++ optional cfg.enableNginx 443;
    }
  ]);
}
