# vector-log-metrics-forward
#
# A NixOS module that ships journald + nginx logs (and, optionally, Prometheus
# metrics) off the box with Vector. The local journald is treated as a
# short-retention *buffer* only — the durable copy lives on one or more
# upstream collectors. Events fan out to every upstream in parallel behind a
# disk buffer, so whichever sink is reachable first wins.
#
# Drop into your host modules and set `behaviors.logs.useVector = true` plus an
# `upstream`. Nothing here is host- or fleet-specific; every site value is an
# option with a generic default.
#
# See README.md for the why and the traps.

{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.behaviors.logs;

  forwardMetricsEnabled =
    cfg.enableMetrics
    && (
      config.services.prometheus.exporters.node.enable
      || cfg.postgresqlExporter.enable
      || cfg.enableGPUMetrics
      || config.services.prometheus.exporters.nut.enable
    );

  # Build the VRL predicate that drops known-noisy journald lines *before* they
  # fan out to every downstream transform. Each rule drops a message when it
  # comes from `unit` AND its text contains `contains`. Empty list => pass all.
  dropNoisePredicate =
    if cfg.dropUnitNoise == [ ] then
      "true"
    else
      lib.concatStringsSep " && " (
        map (r: ''!(unit == "${r.unit}" && contains(msg, "${r.contains}"))'') cfg.dropUnitNoise
      );
in
{
  options.behaviors.logs = {
    useVector = mkOption {
      type = types.bool;
      default = false;
      description = "Master switch: run the Vector log/metric forwarder on this host.";
    };

    upstream = mkOption {
      type = with types; either str (listOf str);
      default = "";
      description = ''
        Upstream collector host(s) to forward to. Accepts either a single
        string (one Vector sink) or a list of strings (one sink per entry).

        With a list, events go to all upstreams in parallel — whichever is
        reachable wins, and the disk buffer holds anything a slow/unreachable
        sink hasn't accepted yet. This is the point of the pattern: e.g. a LAN
        relay that is reachable immediately plus a VPN/tailnet host that only
        becomes reachable a bit later.
      '';
      example = [
        "relay.lan"
        "collector.example.com"
      ];
    };

    logsPort = mkOption {
      type = types.port;
      default = 4044;
      description = "TCP port the upstream Vector receiver listens on for logs.";
    };

    metricsPort = mkOption {
      type = types.port;
      default = 4045;
      description = "TCP port the upstream Vector receiver listens on for metrics.";
    };

    compression = mkOption {
      type = types.bool;
      default = true;
      description = "Compress the forwarded Vector stream(s) on the wire.";
    };

    enableMetrics = mkOption {
      type = types.bool;
      default = false;
      description = "Also scrape local Prometheus exporters and forward the metrics.";
    };

    scrapeIntervalSecs = mkOption {
      type = types.int;
      default = 60;
      description = ''
        How often to scrape the local Prometheus exporters before forwarding.
        Raising this proportionally lowers the forwarded metric volume.
      '';
    };

    enableNginxLogs = mkOption {
      type = types.bool;
      default = false;
      description = "Forward nginx access and error logs (requires services.nginx).";
    };

    enableFail2banLogs = mkOption {
      type = types.bool;
      default = false;
      description = "Forward fail2ban logs (requires services.fail2ban).";
    };

    enableLogReceiver = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Turn this host into an upstream collector: open a Vector source socket
        that accepts logs (and metrics, if enableMetrics) from other nodes.
      '';
    };

    receiverInterface = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "vpn0";
      description = ''
        When acting as a receiver, restrict the opened firewall ports to this
        interface only (e.g. a VPN interface). Null opens them on all
        interfaces — only do that on a trusted network.
      '';
    };

    enableGeoIP = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enrich nginx access logs with GeoIP data (country/city/coords/ASN).
        Requires GeoLite2-City.mmdb and GeoLite2-ASN.mmdb present at
        geoipDatabasePath (provisioned by whatever updater you run).
      '';
    };

    geoipDatabasePath = mkOption {
      type = types.path;
      default = "/var/lib/geoip-databases";
      description = "Directory holding GeoLite2-City.mmdb and GeoLite2-ASN.mmdb.";
    };

    geoipUpdaterService = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "geoip-updater.service";
      description = ''
        Systemd unit that refreshes the GeoIP databases. If set, Vector is
        ordered `after`/`wants` it so it never starts against a missing or
        half-written mmdb. Null disables the ordering.
      '';
    };

    enableGPUMetrics = mkOption {
      type = types.bool;
      default = false;
      description = "Scrape NVIDIA GPU metrics via prometheus-nvidia-gpu-exporter (:9835).";
    };

    postgresqlExporter = mkOption {
      description = "Optional PostgreSQL Prometheus exporter to scrape and forward.";
      default = { };
      type = types.submodule {
        options = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = "Scrape a local postgres exporter and forward its metrics.";
          };
          port = mkOption {
            type = types.port;
            default = 9187;
            description = "Port the postgres exporter serves /metrics on.";
          };
        };
      };
    };

    upsName = mkOption {
      type = types.str;
      default = "ups";
      description = ''
        NUT UPS name to target when services.prometheus.exporters.nut is
        enabled (the exporter is scraped at
        /ups_metrics?target=<upsName>@localhost:3493).
      '';
    };

    dropUnitNoise = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            unit = mkOption {
              type = types.str;
              description = "Exact _SYSTEMD_UNIT the noisy line comes from.";
            };
            contains = mkOption {
              type = types.str;
              description = "Substring that marks the line as noise to drop.";
            };
          };
        }
      );
      default = [ ];
      example = [
        {
          unit = "some-chatty.service";
          contains = "context canceled";
        }
      ];
      description = ''
        Journald lines to drop *before* they fan out to any downstream
        transform. Each rule drops a message that both comes from `unit` and
        contains `contains`. Keep the list short; this is for known,
        high-volume, zero-value spam.
      '';
    };

    journaldMaxUse = mkOption {
      type = types.str;
      default = "500M";
      description = "SystemMaxUse for journald. Kept small: journald is only a buffer here.";
    };

    journaldMaxRetentionSec = mkOption {
      type = types.int;
      default = 24 * 3600;
      description = "MaxRetentionSec for journald. Kept short: the durable copy is upstream.";
    };

    vectorBufferType = mkOption {
      type = types.enum [
        "disk"
        "memory"
      ];
      default = "disk";
      description = ''
        Buffer type for the forwarding sinks. `disk` survives restarts and
        upstream outages (recommended); `memory` is faster but loses buffered
        events on restart.
      '';
    };

    vectorBufferMaxSize = mkOption {
      type = types.int;
      default = 1073741824; # 1 GiB
      description = "Maximum size of Vector's on-disk sink buffer, in bytes.";
    };
  };

  config = lib.mkIf cfg.useVector {
    assertions = [
      {
        assertion =
          if builtins.isList cfg.upstream then
            cfg.upstream != [ ] && !(lib.elem "" cfg.upstream)
          else
            cfg.upstream != "";
        message = "behaviors.logs: upstream must be set (string or non-empty list of strings) when useVector is true";
      }
    ];

    services.prometheus.exporters.node = mkIf cfg.enableMetrics {
      enable = true;
      port = 9100;
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
      disabledCollectors = [
        "powersupplyclass"
      ];
    };

    systemd.services.nvidia-gpu-exporter = mkIf cfg.enableGPUMetrics {
      description = "NVIDIA GPU Prometheus Exporter";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.prometheus-nvidia-gpu-exporter}/bin/nvidia_gpu_exporter --web.listen-address=:9835";
        Restart = "always";
        RestartSec = "5s";
        DynamicUser = true;
        SupplementaryGroups = [ "video" ];
      };
      path = [ config.hardware.nvidia.package ];
    };

    services.vector = {
      enable = true;
      package = pkgs.vector;
      journaldAccess = true;
      settings = {
        enrichment_tables = mkIf cfg.enableGeoIP {
          geoip_table = {
            type = "geoip";
            path = "${cfg.geoipDatabasePath}/GeoLite2-City.mmdb";
          };
          asn_table = {
            type = "geoip";
            path = "${cfg.geoipDatabasePath}/GeoLite2-ASN.mmdb";
          };
        };

        sources.journald = {
          type = "journald";
          current_boot_only = true;
        };

        # Drop known-noisy journald lines once, up front, so the spam never
        # reaches any downstream transform. This transform is the base
        # "filtered journald" node every other journald consumer reads from.
        transforms.journald_filtered = {
          type = "filter";
          inputs = [ "journald" ];
          condition = {
            type = "vrl";
            source = ''
              unit = string(._SYSTEMD_UNIT) ?? ""
              msg = string(.message) ?? ""
              ${dropNoisePredicate}
            '';
          };
        };

        sources.vector_listen = mkIf cfg.enableLogReceiver {
          type = "vector";
          address = "0.0.0.0:${toString cfg.logsPort}";
          version = "2";
        };

        sources.nginx_access = mkIf (cfg.enableNginxLogs && config.services.nginx.enable) {
          type = "file";
          include = [ "/var/log/nginx/access.log" ];
          read_from = "end";
          fingerprint = {
            strategy = "device_and_inode";
          };
        };

        sources.nginx_error = mkIf (cfg.enableNginxLogs && config.services.nginx.enable) {
          type = "file";
          include = [ "/var/log/nginx/error.log" ];
          read_from = "end";
          fingerprint = {
            strategy = "device_and_inode";
          };
        };

        sources.prometheus_scrape = mkIf forwardMetricsEnabled {
          type = "prometheus_scrape";
          endpoints = lib.flatten [
            (lib.optional config.services.prometheus.exporters.node.enable "http://localhost:${toString config.services.prometheus.exporters.node.port}/metrics")
            (lib.optional cfg.postgresqlExporter.enable "http://localhost:${toString cfg.postgresqlExporter.port}/metrics")
            (lib.optional cfg.enableGPUMetrics "http://localhost:9835/metrics")
            (lib.optional config.services.prometheus.exporters.nut.enable "http://localhost:${toString config.services.prometheus.exporters.nut.port}/ups_metrics?target=${cfg.upsName}@localhost:3493")
          ];
          scrape_interval_secs = cfg.scrapeIntervalSecs;
          scrape_timeout_secs = 15;
        };

        transforms.parse_nginx_access = mkIf (cfg.enableNginxLogs && config.services.nginx.enable) {
          type = "remap";
          inputs = [ "nginx_access" ];
          source = ''
            # Non-aborting parse ON PURPOSE. TLS probers hitting a plaintext :80
            # log raw ClientHello bytes that embed a literal `"` inside the
            # request field, which terminates the `[^"]+` capture early and
            # fails the regex. The aborting form (parse_regex!) turned every such
            # line into a Vector ERROR and DROPPED it. With the non-aborting
            # form we forward the raw line instead (tagged nginx_access_raw).
            parsed, err = parse_regex(.message, r'^(?P<remote_addr>\S+) - (?P<remote_user>\S+) \[(?P<time_local>[^\]]+)\] "(?P<request>[^"]+)" (?P<status>\d+) (?P<body_bytes_sent>\d+) "(?P<http_referer>[^"]+)" "(?P<http_user_agent>[^"]+)" "(?P<host>[^"]+)"')
            if err == null {
              . |= parsed
              .labels.source = "nginx_access"
              .labels.host = "${config.networking.hostName}"
              .labels.vhost = .host
              del(.message)
            } else {
              .labels.source = "nginx_access_raw"
              .labels.host = "${config.networking.hostName}"
            }
          '';
        };

        transforms.parse_nginx_error = mkIf (cfg.enableNginxLogs && config.services.nginx.enable) {
          type = "remap";
          inputs = [ "nginx_error" ];
          source = ''
            .labels.source = "nginx_error"
            .labels.host = "${config.networking.hostName}"
          '';
        };

        transforms.geoip_enrich =
          mkIf (cfg.enableNginxLogs && cfg.enableGeoIP && config.services.nginx.enable)
            {
              type = "remap";
              inputs = [ "parse_nginx_access" ];
              source = ''
                . = .

                if exists(.remote_addr) {
                  ip = string!(.remote_addr)
                  if starts_with(ip, "10.") || starts_with(ip, "172.") || starts_with(ip, "192.168.") || starts_with(ip, "127.") || ip == "::1" {
                    .geoip = {
                      "status": "private_ip",
                      "ip": ip
                    }
                  } else {
                    geoip_result, err = get_enrichment_table_record("geoip_table", { "ip": .remote_addr })

                    if err != null {
                      .geoip = {
                        "status": "lookup_error",
                        "error": to_string(err),
                        "ip": ip
                      }
                    } else if geoip_result == null {
                      .geoip = {
                        "status": "not_found",
                        "ip": ip
                      }
                    } else {
                      .geoip = {}

                      if exists(geoip_result.city_name) && geoip_result.city_name != null {
                        .geoip.city_name = string!(geoip_result.city_name)
                      }

                      if exists(geoip_result.region_name) && geoip_result.region_name != null {
                        .geoip.region_name = string!(geoip_result.region_name)
                      }

                      if exists(geoip_result.country_code) && geoip_result.country_code != null {
                        .geoip.country_code = string!(geoip_result.country_code)
                        .labels.country = downcase(string!(geoip_result.country_code))
                      }

                      if exists(geoip_result.latitude) {
                        .geoip.latitude = geoip_result.latitude
                      }
                      if exists(geoip_result.longitude) {
                        .geoip.longitude = geoip_result.longitude
                      }

                      asn_result, asn_err = get_enrichment_table_record("asn_table", { "ip": .remote_addr })
                      if asn_err == null && asn_result != null {
                        if exists(asn_result.autonomous_system_number) {
                          .geoip.as_number = asn_result.autonomous_system_number
                        }
                        if exists(asn_result.autonomous_system_organization) && asn_result.autonomous_system_organization != null {
                          .geoip.as_organization = string!(asn_result.autonomous_system_organization)
                        }
                      }
                    }
                  }
                }
              '';
            };

        transforms.filter_fail2ban = mkIf (cfg.enableFail2banLogs && config.services.fail2ban.enable) {
          type = "filter";
          inputs = [ "journald_filtered" ];
          condition = ''._SYSTEMD_UNIT == "fail2ban.service"'';
        };

        transforms.add_labels = {
          type = "remap";
          inputs =
            [ "journald_filtered" ]
            ++ (lib.optional cfg.enableLogReceiver "vector_listen")
            ++ (lib.optional (
              cfg.enableNginxLogs && cfg.enableGeoIP && config.services.nginx.enable
            ) "geoip_enrich")
            ++ (lib.optional (
              cfg.enableNginxLogs && !cfg.enableGeoIP && config.services.nginx.enable
            ) "parse_nginx_access")
            ++ (lib.optional (cfg.enableNginxLogs && config.services.nginx.enable) "parse_nginx_error")
            ++ (lib.optional (cfg.enableFail2banLogs && config.services.fail2ban.enable) "filter_fail2ban");
          source = ''
            if !exists(.labels.host) {
              .labels.host = "${config.networking.hostName}"
              if exists(.host) {
                .labels.host = .host
              }
            }
            if exists(._SYSTEMD_UNIT) {
              unit_raw = string!(._SYSTEMD_UNIT)
              .labels.unit = replace(unit_raw, r'@[^.]+', "@")
            } else if exists(._SYSTEMD_USER_UNIT) {
              unit_raw = string!(._SYSTEMD_USER_UNIT)
              .labels.unit = "user:" + replace(unit_raw, r'@[^.]+', "@")
            } else {
              .labels.unit = "none"
            }
            if !exists(.labels.source) {
              .labels.source = "journald"
            }
            if !exists(.labels.severity) {
              src = string!(.labels.source)
              if src == "nginx_access" {
                code = to_int(.status) ?? 0
                if code >= 500 {
                  .labels.severity = "error"
                } else if code >= 400 {
                  .labels.severity = "warn"
                } else {
                  .labels.severity = "info"
                }
              } else if src == "nginx_error" {
                .labels.severity = "error"
              } else if exists(.PRIORITY) {
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
          '';
        };

        transforms.label_metrics = mkIf forwardMetricsEnabled {
          type = "remap";
          inputs = [ "prometheus_scrape" ];
          source = ''
            .tags.host = "${config.networking.hostName}"
            if exists(.name) && starts_with(string!(.name), "pg_") {
              .tags.instance = "${config.networking.hostName}:${toString cfg.postgresqlExporter.port}"
              .tags.job = "postgresql"
            } else if exists(.name) && starts_with(string!(.name), "nvidia_") {
              .tags.instance = "${config.networking.hostName}:9835"
              .tags.job = "nvidia-gpu"
            } else if exists(.name) && starts_with(string!(.name), "network_ups_tools_") {
              .tags.instance = "${config.networking.hostName}:${
                toString (
                  if config.services.prometheus.exporters.nut.enable then
                    config.services.prometheus.exporters.nut.port
                  else
                    9199
                )
              }"
              .tags.job = "ups"
            } else {
              .tags.instance = "${config.networking.hostName}:${toString config.services.prometheus.exporters.node.port}"
              .tags.job = "node"
            }
          '';
        };

        sinks =
          let
            upstreams = if builtins.isList cfg.upstream then cfg.upstream else [ cfg.upstream ];
            sanitize = s: lib.replaceStrings [ "." ":" "/" ] [ "_" "_" "_" ] s;
            buf =
              if cfg.vectorBufferType == "memory" then
                {
                  type = "memory";
                  max_events = 10000;
                  when_full = "block";
                }
              else
                {
                  type = "disk";
                  max_size = cfg.vectorBufferMaxSize;
                  when_full = "block";
                };
            # One sink per upstream. Events fan out to ALL of them in parallel,
            # each with its own buffer — so a slow or down upstream never stalls
            # the others, and whichever is reachable first carries the data.
            forwardLogs = lib.listToAttrs (
              map (u: {
                name = "forward_logs_${sanitize u}";
                value = {
                  type = "vector";
                  inputs = [ "add_labels" ];
                  address = "${u}:${toString cfg.logsPort}";
                  compression = cfg.compression;
                  buffer = buf;
                  acknowledgements.enabled = true;
                  request = {
                    timeout_secs = 120;
                    retry_initial_backoff_secs = 1;
                    retry_max_duration_secs = 300;
                  };
                  batch.max_bytes = 1048576;
                };
              }) upstreams
            );
            forwardMetrics =
              if forwardMetricsEnabled then
                lib.listToAttrs (
                  map (u: {
                    name = "forward_metrics_${sanitize u}";
                    value = {
                      type = "vector";
                      inputs = [ "label_metrics" ];
                      address = "${u}:${toString cfg.metricsPort}";
                      compression = cfg.compression;
                      buffer = buf;
                      acknowledgements.enabled = false;
                      request = {
                        timeout_secs = 120;
                        retry_initial_backoff_secs = 1;
                        retry_max_duration_secs = 300;
                      };
                      batch.max_bytes = 1048576;
                    };
                  }) upstreams
                )
              else
                { };
          in
          forwardLogs // forwardMetrics;
      };
    };

    # journald is deliberately a short-retention BUFFER: the durable copy lives
    # upstream. Keep it small so a wedged upstream can't blow up local disk.
    services.journald = {
      extraConfig = ''
        SystemMaxUse=${cfg.journaldMaxUse}
        MaxRetentionSec=${toString cfg.journaldMaxRetentionSec}
      '';
    };

    systemd.services.vector = {
      # Order Vector AFTER the GeoIP updater so it never starts against a
      # missing or half-written mmdb.
      after = mkIf (cfg.enableGeoIP && cfg.geoipUpdaterService != null) [ cfg.geoipUpdaterService ];
      wants = mkIf (cfg.enableGeoIP && cfg.geoipUpdaterService != null) [ cfg.geoipUpdaterService ];
      serviceConfig = {
        CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
        AmbientCapabilities = [ "CAP_DAC_READ_SEARCH" ];
        ReadOnlyPaths = mkMerge [
          (mkIf (cfg.enableNginxLogs && config.services.nginx.enable) [ "/var/log/nginx" ])
          (mkIf cfg.enableGeoIP [ cfg.geoipDatabasePath ])
        ];
        SupplementaryGroups = mkIf (cfg.enableNginxLogs && config.services.nginx.enable) [ "nginx" ];
      };
      environment = mkIf cfg.enableGeoIP {
        GEOIP_DATABASE_PATH = cfg.geoipDatabasePath;
      };
    };

    virtualisation.docker.logDriver = mkIf config.virtualisation.docker.enable "journald";

    # Open the receiver ports. If receiverInterface is set, restrict to that
    # interface (e.g. a VPN interface) instead of exposing them everywhere.
    networking.firewall = mkIf cfg.enableLogReceiver (
      let
        ports = [ cfg.logsPort ] ++ (lib.optional cfg.enableMetrics cfg.metricsPort);
      in
      if cfg.receiverInterface != null then
        {
          interfaces.${cfg.receiverInterface}.allowedTCPPorts = ports;
        }
      else
        {
          allowedTCPPorts = ports;
        }
    );
  };
}
