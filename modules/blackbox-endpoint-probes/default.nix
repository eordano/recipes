{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.blackboxEndpointProbes;

  # Blackbox exporter probe modules.
  #
  # TRAP: `http_2xx` deliberately lists 4xx codes in `valid_status_codes`, so it
  # only fails on connection/TLS/timeout errors — a 404 still reads as SUCCESS.
  # That makes it a "server is up and routing" check. Use `http_strict_2xx`
  # (empty list = real 2xx-only) for any endpoint where a 4xx should page.
  #
  # All modules pin IPv4 (`preferred_ip_protocol = "ip4"`) so a probe result
  # doesn't silently depend on the box's IPv6 reachability.
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
      listenAddress = cfg.listenAddress;
      port = cfg.port;
      configFile = (pkgs.formats.yaml { }).generate "blackbox.yml" {
        modules = cfg.modules;
      };
    };

    services.prometheus.scrapeConfigs = [
      {
        job_name = "blackbox";
        scrape_interval = cfg.probeInterval;
        scrape_timeout = cfg.probeTimeout;
        metrics_path = "/probe";

        # Group targets by blackbox module. Each static_config carries the
        # module name as a custom `__blackbox_module` meta-label so the relabel
        # stage below can turn it into the `module` query param.
        static_configs = map (m: {
          labels.__blackbox_module = m;
          targets = map (t: t.url) (filter (t: t.module == m) cfg.targets);
        }) (lib.unique (map (t: t.module) cfg.targets));

        # The standard, non-obvious blackbox relabel indirection. Without it,
        # Prometheus would try to scrape each target URL directly instead of
        # asking the exporter to probe it:
        #   1. copy the target (`__address__`) into `__param_target`
        #   2. copy the meta-label into `__param_module`
        #   3. keep the target URL as the `instance` label (readable in graphs)
        #   4. rewrite `__address__` to the exporter itself, so the actual HTTP
        #      GET becomes  http://<exporter>/probe?target=<url>&module=<module>
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
        # Trailing per-target relabel: map each probed URL back to its short
        # `service` label. The URL is `lib.escapeRegex`'d so a target containing
        # regex metacharacters (?, +, . …) can't accidentally match and
        # mislabel a different target.
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
