{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.modules.services.pypi-cache;

  # Create a Python environment with proxpi
  proxpiEnv = pkgs.python3.withPackages (
    ps: with ps; [
      ps.flask
      ps.requests
      ps.lxml
      ps.beautifulsoup4
      ps.gunicorn
      (ps.buildPythonPackage rec {
        pname = "proxpi";
        version = "1.2.0";
        pyproject = true;

        src = pkgs.fetchPypi {
          inherit pname version;
          sha256 = "sha256-7Z4NdBJrQK9cd4ZDTLSYfjsw4YNnio9hvUptamUzrjY=";
        };

        build-system = with ps; [
          setuptools
          setuptools-scm
        ];

        nativeBuildInputs = [ ps.pythonRelaxDepsHook ];
        pythonRelaxDeps = [ "lxml" ];

        propagatedBuildInputs = with ps; [
          flask
          requests
          lxml
          beautifulsoup4
        ];

        doCheck = false;
      })
    ]
  );
in
{
  options.modules.services.pypi-cache = {
    enable = mkEnableOption "PyPI caching proxy";

    uid = mkOption {
      type = types.int;
      default = 1326;
      description = "User ID for the service user";
    };

    gid = mkOption {
      type = types.int;
      default = 1326;
      description = "Group ID for the service group";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/cache/pypi-proxy";
      description = "Directory to store cached Python packages";
    };

    domain = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Domain name for the PyPI cache proxy";
    };

    acmeHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "ACME host for SSL certificates";
    };

    port = mkOption {
      type = types.int;
      default = 1326;
      description = "Port to run the service on";
    };

    nginxCacheDir = mkOption {
      type = types.str;
      default = "/var/cache/nginx/pypi";
      description = "Directory for nginx proxy cache";
    };

    nginxCacheSize = mkOption {
      type = types.str;
      default = "10g";
      description = "Maximum size of nginx cache";
    };

    nginxCacheTime = mkOption {
      type = types.str;
      default = "30d";
      description = "How long to cache packages in nginx";
    };

    enableSSL = mkOption {
      type = types.bool;
      default = true;
      description = "Enable SSL for the cache proxy";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.domain != null;
        message = "modules.services.pypi-cache: domain must be set when enabled";
      }
      {
        assertion = !cfg.enableSSL || cfg.acmeHost != null;
        message = "modules.services.pypi-cache: acmeHost must be set when SSL is enabled";
      }
    ];

    # User and group setup
    users = {
      users.pypi-cache = {
        uid = cfg.uid;
        isSystemUser = true;
        group = "pypi-cache";
      };
      groups.pypi-cache.gid = cfg.gid;
    };

    # Directory setup
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 ${toString cfg.uid} ${toString cfg.gid} - -"
      "d ${cfg.nginxCacheDir} 0750 nginx nginx - -"
    ];

    # Systemd service
    systemd.services.pypi-cache = {
      description = "PyPI caching proxy";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        PROXPI_CACHE_DIR = cfg.dataDir;
        PROXPI_CACHE_SIZE = "5368709120"; # 5GB default
        PROXPI_INDEX_TTL = "1800"; # 30 minutes
        PROXPI_CONNECT_TIMEOUT = "5";
        PROXPI_READ_TIMEOUT = "10";
      };

      serviceConfig = {
        Type = "simple";
        User = "pypi-cache";
        Group = "pypi-cache";
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${proxpiEnv}/bin/gunicorn -b 127.0.0.1:${toString cfg.port} -w 4 proxpi.server:app";
        Restart = "always";
        RestartSec = "10s";

        # Security hardening
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
        NoNewPrivileges = true;
        PrivateDevices = true;
        ProtectHostname = true;
        ProtectClock = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RemoveIPC = true;
        PrivateMounts = true;
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
          "~@mount"
        ];
        SystemCallArchitectures = "native";
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        MemoryDenyWriteExecute = true;
        LockPersonality = true;
        UMask = "0077";
      };
    };

    # Nginx configuration with caching for offline resilience
    services.nginx = {
      enable = mkDefault true;

      appendHttpConfig = mkAfter ''
        proxy_cache_path ${cfg.nginxCacheDir}
          levels=1:2
          keys_zone=pypicache:100m
          max_size=${cfg.nginxCacheSize}
          inactive=${cfg.nginxCacheTime}
          use_temp_path=off;
      '';

      virtualHosts.${cfg.domain} = {
        forceSSL = mkDefault cfg.enableSSL;
        useACMEHost = mkIf cfg.enableSSL (mkDefault cfg.acmeHost);

        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}/";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_cache pypicache;
            proxy_cache_valid 200 301 302 ${cfg.nginxCacheTime};
            proxy_cache_valid 404 1m;
            proxy_cache_valid any 10m;

            proxy_cache_use_stale error timeout http_500 http_502 http_503 http_504 updating;
            proxy_cache_revalidate on;
            proxy_cache_lock on;
            proxy_cache_lock_timeout 5m;
            proxy_cache_background_update on;

            proxy_cache_key $scheme$host$request_uri;
            add_header X-Cache-Status $upstream_cache_status always;

            proxy_connect_timeout 5s;
            proxy_read_timeout 30s;
            proxy_send_timeout 30s;
          '';
        };
      };
    };

    systemd.services.nginx.serviceConfig.ReadWritePaths = [ cfg.nginxCacheDir ];
  };
}
