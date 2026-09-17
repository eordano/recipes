{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.blackboxEndpointProbes;

  defaultModules = {
    http_2xx = {
      prober = "http";
      timeout = "5s";
      http = {
        valid_status_codes = [
          200
          201
          202
          204
          301
          302
          307
          308
          400
          401
          403
          404
        ];
        method = "GET";
        follow_redirects = true;
        fail_if_ssl = false;
        fail_if_not_ssl = false;
        preferred_ip_protocol = "ip4";
      };
    };
    http_strict_2xx = {
      prober = "http";
      timeout = "5s";
      http = {
        valid_status_codes = [ ];
        method = "GET";
        follow_redirects = true;
        preferred_ip_protocol = "ip4";
      };
    };
    tcp_connect = {
      prober = "tcp";
      timeout = "5s";
    };
    icmp = {
      prober = "icmp";
      timeout = "5s";
      icmp.preferred_ip_protocol = "ip4";
    };
  };

in
{
  options.services.blackboxEndpointProbes = {
    enable = mkEnableOption "Blackbox exporter + a Prometheus probe scrape job driven from one targets list";

    port = mkOption {
      type = types.int;
      default = 9115;
      description = "Blackbox exporter listen port (bound to localhost).";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        Address the blackbox exporter binds to. Both the exporter and the
        generated scrape job use this, so leaving it on loopback keeps the
        probe surface off the network.
      '';
    };

    probeInterval = mkOption {
      type = types.str;
      default = "30s";
      description = "How often Prometheus runs each probe.";
    };

    probeTimeout = mkOption {
      type = types.str;
      default = "10s";
      description = "Per-scrape timeout. Keep it >= the module `timeout`.";
    };

    targets = mkOption {
      description = ''
        List of probe targets. Each target emits
        `probe_success{service=<name>} 0|1` and
        `probe_duration_seconds{service=<name>}`.
      '';
      type = types.listOf (
        types.submodule {
          options = {
            service = mkOption {
              type = types.str;
              description = "Short label for the service (ends up as the `service` label).";
              example = "api";
            };
            url = mkOption {
              type = types.str;
              description = "Probe target. URL for http_* modules; host:port for tcp_connect; host for icmp.";
              example = "https://example.com/health";
            };
            module = mkOption {
              type = types.enum [
                "http_2xx"
                "http_strict_2xx"
                "tcp_connect"
                "icmp"
              ];
              default = "http_2xx";
              description = ''
                Which blackbox module probes this target. `http_2xx` treats 4xx
                as success (routing check); `http_strict_2xx` requires a real 2xx.
              '';
            };
          };
        }
      );
      default = [ ];
    };

    modules = mkOption {
      type = types.attrs;
      default = defaultModules;
      description = "Blackbox exporter module config. Override to add or replace probe definitions.";
    };
  };

  config = mkIf cfg.enable {
    services.prometheus.exporters.blackbox = {
      enable = true;
      inherit (cfg) listenAddress;
      inherit (cfg) port;
      configFile = (pkgs.formats.yaml { }).generate "blackbox.yml" {
        inherit (cfg) modules;
      };
    };

    services.prometheus.scrapeConfigs = [
      {
        job_name = "blackbox";
        scrape_interval = cfg.probeInterval;
        scrape_timeout = cfg.probeTimeout;
        metrics_path = "/probe";

        static_configs = map (m: {
          labels.__blackbox_module = m;
          targets = map (t: t.url) (filter (t: t.module == m) cfg.targets);
        }) (lib.unique (map (t: t.module) cfg.targets));

        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__blackbox_module" ];
            target_label = "__param_module";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "${cfg.listenAddress}:${toString cfg.port}";
          }
        ]
        ++ (map (t: {
          source_labels = [ "__param_target" ];
          regex = lib.escapeRegex t.url;
          target_label = "service";
          replacement = t.service;
        }) cfg.targets);
      }
    ];
  };
}
