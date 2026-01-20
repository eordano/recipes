{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.modules.services.nix-cache;
in
{
  options.modules.services.nix-cache = {
    enable = mkEnableOption "Nix binary cache proxy";

    domain = mkOption {
      type = types.str;
      description = "Domain name for the Nix cache proxy";
    };

    acmeHost = mkOption {
      type = types.str;
      description = "ACME host for SSL certificates";
    };

    cacheDir = mkOption {
      type = types.str;
      default = "/var/cache/nix-proxy";
      description = "Directory to store cached Nix packages";
    };

    maxCacheSize = mkOption {
      type = types.str;
      default = "500g";
      description = "Maximum size of the cache";
    };

    cacheValidTime = mkOption {
      type = types.str;
      default = "60d";
      description = "How long to cache valid responses (NAR files are content-addressed)";
    };

    upstreamEndpoint = mkOption {
      type = types.str;
      default = "cache.nixos.org";
      description = "Upstream Nix binary cache endpoint";
    };

    upstreamProtocol = mkOption {
      type = types.enum [ "http" "https" ];
      default = "https";
      description = "Protocol to use for upstream connection";
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
        assertion = cfg.domain != "";
        message = "modules.services.nix-cache: domain must be set";
      }
      {
        assertion = !cfg.enableSSL || cfg.acmeHost != "";
        message = "modules.services.nix-cache: acmeHost must be set when SSL is enabled";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.cacheDir} 0750 nginx nginx -"
    ];

    systemd.services.nginx.serviceConfig.ReadWritePaths = [ cfg.cacheDir ];

    services.nginx = {
      enable = mkDefault true;
      recommendedGzipSettings = true;

      appendHttpConfig = mkAfter ''
        proxy_cache_path ${cfg.cacheDir}
          levels=1:2
          keys_zone=nixcache:500m
          max_size=${cfg.maxCacheSize}
          inactive=${cfg.cacheValidTime}
          use_temp_path=off;
      '';

      virtualHosts.${cfg.domain} = {
        forceSSL = mkDefault cfg.enableSSL;
        useACMEHost = mkIf cfg.enableSSL (mkDefault cfg.acmeHost);

        extraConfig = ''
          proxy_connect_timeout 60s;
          proxy_send_timeout 300s;
          proxy_read_timeout 300s;
          directio 4m;
        '';

        locations."/" = {
          proxyPass = "${cfg.upstreamProtocol}://${cfg.upstreamEndpoint}";
          extraConfig = ''
            proxy_cache nixcache;
            proxy_cache_valid 200 302 ${cfg.cacheValidTime};
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;

            proxy_cache_lock on;
            proxy_cache_lock_timeout 600s;
            proxy_cache_lock_age 600s;

            proxy_set_header Host ${cfg.upstreamEndpoint};
            ${optionalString (cfg.upstreamProtocol == "https") ''
              proxy_ssl_server_name on;
              proxy_ssl_name ${cfg.upstreamEndpoint};
            ''}

            proxy_cache_key $uri;

            add_header X-Cache-Status $upstream_cache_status always;

            proxy_buffering off;
            proxy_request_buffering off;
          '';
        };

        locations."/nix-cache-info" = {
          proxyPass = "${cfg.upstreamProtocol}://${cfg.upstreamEndpoint}/nix-cache-info";
          extraConfig = ''
            proxy_cache nixcache;
            proxy_cache_valid 200 1h;
            proxy_set_header Host ${cfg.upstreamEndpoint};
            ${optionalString (cfg.upstreamProtocol == "https") ''
              proxy_ssl_server_name on;
            ''}
            add_header X-Cache-Status $upstream_cache_status always;
          '';
        };
      };
    };
  };
}
