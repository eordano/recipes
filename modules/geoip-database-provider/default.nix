{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.modules.services.geoip-databases;

  inherit (cfg) databases;

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
        MaxMind account + license-key wall -- see README). Point this at your
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
      inherit (cfg) group;
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

    system.activationScripts.geoip-databases = ''
      if [ ! -f ${cfg.dataDir}/${builtins.head cfg.databases} ]; then
        echo "GeoIP databases not found. Starting initial download..."
        ${pkgs.systemd}/bin/systemctl start geoip-updater.service || true
      fi
    '';
  };
}
