{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.modules.services.npm-cache;

  verdaccioConfig = pkgs.writeText "verdaccio-config.yaml" ''
    storage: ${cfg.dataDir}/storage
    plugins: ${cfg.dataDir}/plugins

    web:
      enable: true
      title: Local npm Cache

    auth:
      htpasswd:
        file: ${cfg.dataDir}/htpasswd

    uplinks:
      npmjs:
        url: https://registry.npmjs.org/
        timeout: 30s
        maxage: 10m
        cache: true

    packages:
      '@*/*':
        access: $all
        publish: $authenticated
        proxy: npmjs

      '**':
        access: $all
        publish: $authenticated
        proxy: npmjs

    server:
      keepAliveTimeout: 60

    middlewares:
      audit:
        enabled: true

    listen: 127.0.0.1:${toString cfg.port}

    log:
      type: stdout
      format: pretty
      level: warn
  '';
in
{
  options.modules.services.npm-cache = {
    enable = mkEnableOption "npm registry caching proxy (Verdaccio)";

    uid = mkOption {
      type = types.int;
      default = 1327;
      description = "User ID for the service user";
    };

    gid = mkOption {
      type = types.int;
      default = 1327;
      description = "Group ID for the service group";
    };

    domain = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Domain name for the npm cache proxy";
    };

    acmeHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "ACME host for SSL certificates";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/verdaccio";
      description = "Directory to store Verdaccio data and cached packages";
    };

    port = mkOption {
      type = types.port;
      default = 4873;
      description = "Internal port for Verdaccio";
    };

    nginxCacheDir = mkOption {
      type = types.str;
      default = "/var/cache/nginx/npm";
      description = "Directory for nginx proxy cache";
    };

    nginxCacheSize = mkOption {
      type = types.str;
      default = "50g";
      description = "Maximum size of the nginx cache";
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
        message = "modules.services.npm-cache: domain must be set when enabled";
      }
      {
        assertion = !cfg.enableSSL || cfg.acmeHost != null;
        message = "modules.services.npm-cache: acmeHost must be set when SSL is enabled";
      }
    ];

    users = {
      users.verdaccio = {
        uid = cfg.uid;
        isSystemUser = true;
        group = "verdaccio";
        home = cfg.dataDir;
      };
      groups.verdaccio.gid = cfg.gid;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 verdaccio verdaccio -"
      "d ${cfg.dataDir}/storage 0755 verdaccio verdaccio -"
      "d ${cfg.dataDir}/plugins 0755 verdaccio verdaccio -"
      "d ${cfg.nginxCacheDir} 0750 nginx nginx -"
    ];

    systemd.services.verdaccio = {
      description = "Verdaccio npm registry proxy";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.verdaccio}/bin/verdaccio --config ${verdaccioConfig}";
        Restart = "always";
        RestartSec = "5s";
        User = "verdaccio";
        Group = "verdaccio";
        StateDirectory = "verdaccio";

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
      };
    };

    services.nginx = {
      enable = mkDefault true;

      appendHttpConfig = mkAfter ''
        proxy_cache_path ${cfg.nginxCacheDir}
          levels=1:2
          keys_zone=npmcache:100m
          max_size=${cfg.nginxCacheSize}
          inactive=${cfg.nginxCacheTime}
          use_temp_path=off;
      '';

      virtualHosts.${cfg.domain} = {
        forceSSL = mkDefault cfg.enableSSL;
        useACMEHost = mkIf cfg.enableSSL (mkDefault cfg.acmeHost);

        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          extraConfig = ''
            proxy_cache npmcache;
            proxy_cache_valid 200 ${cfg.nginxCacheTime};
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
            proxy_cache_lock on;
            add_header X-Cache-Status $upstream_cache_status always;

            proxy_pass_header Authorization;
            proxy_set_header Authorization $http_authorization;
          '';
        };
      };
    };

    systemd.services.nginx.serviceConfig.ReadWritePaths = [ cfg.nginxCacheDir ];
  };
}
