# GeoIP database provider — one shared, credential-free GeoLite2 mirror.
#
# A single oneshot service downloads the GeoLite2 City/Country/ASN databases
# into a shared directory. Its `RemainAfterExit = true` keeps the unit "active"
# after a successful run, so consumer services can order themselves After/Wants
# geoip-updater.service and be guaranteed the .mmdb files exist before they start.
#
# See README.md for the why/traps (P3TERX mirror vs MaxMind account wall,
# RemainAfterExit gating, activation-time initial download, jitter).
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.modules.services.geoip-databases;

  # Each entry: filename written into dataDir. The mirror serves them all
  # under the same path prefix (cfg.mirrorBaseUrl).
  databases = cfg.databases;

  geoipUpdater = pkgs.writeShellScriptBin "geoip-updater" ''
    set -eu

    GEOIP_DIR="${cfg.dataDir}"
    mkdir -p "$GEOIP_DIR"

    for db in ${escapeShellArgs databases}; do
      echo "Downloading $db ..."
      ${pkgs.curl}/bin/curl -fL -o "$GEOIP_DIR/$db" \
        "${cfg.mirrorBaseUrl}/$db"
    done

    echo "GeoIP databases updated successfully!"

    chmod 644 "$GEOIP_DIR"/*.mmdb
  '';

in
{
  options.modules.services.geoip-databases = {
    enable = mkEnableOption "shared GeoIP (GeoLite2) database provider";

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/geoip-databases";
      description = ''
        Directory the .mmdb files are written to. Consumers read this path
        directly (they should never download their own copy).
      '';
    };

    user = mkOption {
      type = types.str;
      default = "geoip";
      description = "System user that owns the data directory and runs the updater.";
    };

    group = mkOption {
      type = types.str;
      default = "geoip";
      description = "System group that owns the data directory.";
    };

    mirrorBaseUrl = mkOption {
      type = types.str;
      default = "https://github.com/P3TERX/GeoLite.mmdb/raw/download";
      description = ''
        Base URL each database filename is appended to. The default is a
        no-auth GitHub mirror of MaxMind's GeoLite2 files (sidesteps the
        MaxMind account + license-key wall — see README). Point this at your
        own mirror or a MaxMind-authenticated endpoint if you prefer.
      '';
    };

    databases = mkOption {
      type = types.listOf types.str;
      default = [
        "GeoLite2-City.mmdb"
        "GeoLite2-Country.mmdb"
        "GeoLite2-ASN.mmdb"
      ];
      description = ''
        Database filenames to fetch from mirrorBaseUrl. The first entry is
        also used as the presence probe by the activation script.
      '';
    };

    updateInterval = mkOption {
      type = types.str;
      default = "weekly";
      description = "How often to refresh the databases (systemd OnCalendar format).";
    };

    randomizedDelaySec = mkOption {
      type = types.str;
      default = "1h";
      description = ''
        Jitter added to the scheduled refresh. Spreads the fetch across a
        fleet so many hosts don't hit the mirror in the same minute.
      '';
    };
  };

  config = mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      description = "GeoIP database updater";
    };

    users.groups.${cfg.group} = { };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.geoip-updater = {
      description = "Update GeoIP databases";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        # Stay "active" after a successful run so consumers ordered
        # After=/Wants=geoip-updater.service only start once the DBs exist.
        RemainAfterExit = true;
        ExecStart = "${geoipUpdater}/bin/geoip-updater";
        User = cfg.user;
        Group = cfg.group;
        StandardOutput = "journal";
        StandardError = "journal";

        PrivateTmp = true;
        ProtectHome = true;
        NoNewPrivileges = true;
        ReadWritePaths = [ cfg.dataDir ];
      };
    };

    systemd.timers.geoip-updater = {
      description = "Update GeoIP databases periodically";
      wantedBy = [ "timers.target" ];
      partOf = [ "geoip-updater.service" ];

      timerConfig = {
        OnCalendar = cfg.updateInterval;
        OnBootSec = "5min";
        Persistent = true;
        RandomizedDelaySec = cfg.randomizedDelaySec;
      };
    };

    # First-boot / first-deploy: pull the databases immediately so a consumer
    # deployed alongside this module doesn't find an empty directory before the
    # timer's OnBootSec fires. `|| true` keeps a failed download from aborting
    # activation.
    system.activationScripts.geoip-databases = ''
      if [ ! -f ${cfg.dataDir}/${builtins.head cfg.databases} ]; then
        echo "GeoIP databases not found. Starting initial download..."
        ${pkgs.systemd}/bin/systemctl start geoip-updater.service || true
      fi
    '';
  };
}
