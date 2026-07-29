# pypi-cache-proxy — a two-layer caching proxy for PyPI.
#
# proxpi (Flask under gunicorn on localhost) is the inner proxy; nginx wraps
# it with a larger disk-backed cache. The outage resilience lives entirely in
# the nginx layer — see the README for why. This module is self-contained:
# drop it into your modules list and set `enable = true` plus a `domain`.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.modules.services.pypi-cache;

  # proxpi is not in nixpkgs, so it is built inline here. `pythonRelaxDeps`
  # strips proxpi's exact lxml pin so nixpkgs' lxml satisfies it without a
  # source rebuild of lxml.
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
    enable = mkEnableOption "PyPI cache proxy service";

    user = mkOption {
      type = types.str;
      default = "pypi-cache";
      description = "System user the proxpi service runs as.";
    };

    group = mkOption {
      type = types.str;
      default = "pypi-cache";
      description = "System group the proxpi service runs as.";
    };

    uid = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "Optional fixed UID for the service user (null = auto-allocate).";
    };

    gid = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "Optional fixed GID for the service group (null = auto-allocate).";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/pypi-cache";
      description = "Directory where the inner proxpi proxy stores cached packages.";
    };

    domain = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "pypi.example.com";
      description = "Virtual host name nginx serves the cache on. Required when enabled.";
    };

    acmeHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "example.com";
      description = ''
        Existing ACME certificate host to reuse for TLS (`useACMEHost`). Leave
        null to disable forced SSL / bring your own TLS wiring.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 5000;
      description = "Localhost port the inner proxpi/gunicorn process listens on.";
    };

    proxpiCacheSize = mkOption {
      type = types.int;
      default = 5368709120; # 5 GiB
      description = "Inner proxpi package cache size, in bytes.";
    };

    nginxCacheDir = mkOption {
      type = types.str;
      default = "/var/cache/nginx/pypi";
      description = "Directory for the outer nginx disk cache.";
    };

    nginxCacheSize = mkOption {
      type = types.str;
      default = "10g";
      description = "Maximum size of the nginx disk cache (nginx size syntax).";
    };

    nginxCacheTime = mkOption {
      type = types.str;
      default = "30d";
      description = "How long items stay valid / inactive in the nginx cache.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.domain != null;
        message = "modules.services.pypi-cache: domain must be set when enabled";
      }
    ];

    users = {
      users.${cfg.user} = {
        uid = mkIf (cfg.uid != null) cfg.uid;
        isSystemUser = true;
        group = cfg.group;
      };
      groups.${cfg.group} = {
        gid = mkIf (cfg.gid != null) cfg.gid;
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.nginxCacheDir} 0750 nginx nginx - -"
    ];

    systemd.services.pypi-cache = {
      description = "PyPI caching proxy";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        PROXPI_CACHE_DIR = cfg.dataDir;
        PROXPI_CACHE_SIZE = toString cfg.proxpiCacheSize;
        PROXPI_INDEX_TTL = "1800";
        PROXPI_CONNECT_TIMEOUT = "5";
        PROXPI_READ_TIMEOUT = "10";
      };

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${proxpiEnv}/bin/gunicorn -b 127.0.0.1:${toString cfg.port} -w 4 proxpi.server:app";
        Restart = "always";
        RestartSec = "10s";

        # Hardening. proxpi only needs to read/write its own cache dir.
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
        MountAPIVFS = true;

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
        KeyringMode = "private";
        ProtectProc = "invisible";
        ProcSubset = "pid";
      };
    };

    services.nginx = {
      enable = lib.mkDefault true;

      appendHttpConfig = lib.mkAfter ''
        proxy_cache_path ${cfg.nginxCacheDir}
          levels=1:2
          keys_zone=pypicache:100m
          max_size=${cfg.nginxCacheSize}
          inactive=${cfg.nginxCacheTime}
          use_temp_path=off;
      '';

      virtualHosts.${cfg.domain} = {
        forceSSL = mkDefault (cfg.acmeHost != null);
        useACMEHost = mkIf (cfg.acmeHost != null) (mkDefault cfg.acmeHost);
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}/";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_cache               pypicache;
            proxy_cache_valid         200 301 302 ${cfg.nginxCacheTime};
            proxy_cache_valid         404 1m;
            proxy_cache_valid         any 10m;

            # Outage resilience: keep serving previously-seen packages when
            # proxpi and/or PyPI are unreachable or erroring.
            proxy_cache_use_stale     error timeout http_500 http_502 http_503 http_504 updating;
            proxy_cache_revalidate    on;
            proxy_cache_lock          on;
            proxy_cache_lock_timeout  5m;
            proxy_cache_background_update on;

            # PyPI index pages send `Cache-Control: no-cache`, which would
            # otherwise defeat the cache entirely. Ignore it and let the
            # proxy_cache_valid rules above govern freshness.
            proxy_ignore_headers      Cache-Control Expires Set-Cookie;

            proxy_cache_key           $scheme$host$request_uri;

            add_header                X-Cache-Status $upstream_cache_status always;

            proxy_connect_timeout     5s;
            proxy_read_timeout        30s;
            proxy_send_timeout        30s;
          '';
        };
      };
    };

    systemd.services.nginx.serviceConfig.ReadWritePaths = [ cfg.nginxCacheDir ];
  };
}
