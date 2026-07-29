# dns-connectivity-probe
#
# A hardened long-running systemd probe that dig+pings a list of targets every
# few seconds and appends timestamped log lines. When resolution or reachability
# flaps intermittently, a later `grep` of the log pins down exactly when it broke.
#
# Two things are deliberate and load-bearing:
#
#   1. logrotate uses `copytruncate`. The probe is a long-running loop that holds
#      the log open with `>>` and never reopens on SIGHUP. A normal
#      rename-and-reopen rotation would leave it writing to the now-unlinked old
#      inode forever, so the "current" log would stop growing. copytruncate
#      copies the file out and truncates the original in place, keeping the same
#      inode the probe is holding.
#
#   2. The service can be ordered *after* a local resolver, so its first queries
#      aren't spurious failures during boot. Set `resolverService` to the unit
#      name of your resolver (e.g. "dnsmasq.service", "unbound.service") and the
#      probe will `wants`/`after` it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.services.dns-connectivity-probe;

  targetsBash = lib.concatMapStringsSep " " (t: ''"${t}"'') cfg.targets;

  checkScript = pkgs.writeShellScript "dns-connectivity-probe" ''
    set -euo pipefail

    LOG_FILE="''${LOGS_DIRECTORY:-${cfg.logDir}}/queries.log"
    QUERIES=(${targetsBash})

    log_result() {
      local timestamp=$(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M:%S')
      echo "$timestamp $1" >> "$LOG_FILE"
    }

    while true; do
      for query in "''${QUERIES[@]}"; do
        if dig_output=$(${pkgs.dnsutils}/bin/dig +time=${toString cfg.digTimeout} +tries=1 "$query" 2>&1); then
          result=$(echo "$dig_output" | ${pkgs.gnugrep}/bin/grep -v '^;' | ${pkgs.gnugrep}/bin/grep -v '^$' | ${pkgs.gawk}/bin/awk '/^[^;]/ {print $NF; exit}')
          query_time=$(echo "$dig_output" | ${pkgs.gnugrep}/bin/grep -oP 'Query time: \K[0-9]+' || echo "N/A")

          if [ -n "$result" ]; then
            log_result "DNS-SUCCESS $query -> $result (''${query_time}ms)"
          else
            log_result "DNS-EMPTY $query -> (no result) (''${query_time}ms)"
          fi
        else
          log_result "DNS-FAILED $query -> error"
        fi

        if ping_result=$(${pkgs.iputils}/bin/ping -c 1 -W 2 "$query" 2>&1 | ${pkgs.gnugrep}/bin/grep -oP 'time=\K[0-9.]+' || echo "timeout"); then
          if [ "$ping_result" = "timeout" ]; then
            log_result "PING-FAILED $query -> timeout"
          else
            log_result "PING-SUCCESS $query -> ''${ping_result}ms"
          fi
        else
          log_result "PING-FAILED $query -> error"
        fi
      done
      sleep ${toString cfg.interval}
    done
  '';
in
{
  options.modules.services.dns-connectivity-probe = {
    enable = lib.mkEnableOption "DNS + reachability black-box probe";

    targets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "localhost"
        "example.com"
      ];
      example = [
        "localhost"
        "your-upstream-resolver.invalid"
        "example.com"
      ];
      description = ''
        Hostnames the probe resolves (dig) and pings on every cycle.
        Include "localhost" to catch local-resolver failures and one or more
        external names to catch upstream/WAN failures.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Seconds to sleep between probe cycles.";
    };

    digTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Per-query dig timeout in seconds (dig +time=).";
    };

    logDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/log/dns-connectivity-probe";
      description = ''
        Directory the probe writes `queries.log` into. Must live under
        `/var/log`: it is mapped to the unit's `LogsDirectory` (the one path a
        `DynamicUser` under `ProtectSystem=strict` may write), and logrotate is
        pointed at the same file. Keeping a single source of truth avoids the
        probe and logrotate drifting onto different paths.
      '';
    };

    keepRotations = lib.mkOption {
      type = lib.types.ints.positive;
      default = 6;
      description = "How many rotated log files logrotate keeps.";
    };

    resolverService = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "dnsmasq.service";
      description = ''
        Optional systemd unit of a local resolver to order the probe after.
        When set, the probe `wants` and comes `after` this unit so its first
        queries during boot aren't spurious failures. Leave null if you have
        no local resolver.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/var/log/" cfg.logDir;
        message = ''
          modules.services.dns-connectivity-probe.logDir must be under /var/log/
          — it is mapped to the unit's LogsDirectory, which is /var/log-relative.
        '';
      }
    ];

    systemd.services.dns-connectivity-probe = {
      description = "DNS + reachability black-box probe";
      after = [ "network.target" ] ++ lib.optional (cfg.resolverService != null) cfg.resolverService;
      wants = lib.optional (cfg.resolverService != null) cfg.resolverService;
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${checkScript}";
        Restart = "always";
        RestartSec = "10s";
        DynamicUser = true;
        # Derived from logDir so the probe's LOGS_DIRECTORY and logrotate's
        # target can never drift onto different paths.
        LogsDirectory = lib.removePrefix "/var/log/" cfg.logDir;

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;

        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictRealtime = true;
      };
    };

    # copytruncate is mandatory here — see the header comment. The probe holds
    # the log open with `>>` and never reopens, so rotation must keep the inode.
    services.logrotate.settings.dns-connectivity-probe = {
      files = "${cfg.logDir}/queries.log";
      frequency = "hourly";
      rotate = cfg.keepRotations;
      compress = true;
      delaycompress = true;
      missingok = true;
      notifempty = true;
      copytruncate = true;
    };
  };
}
