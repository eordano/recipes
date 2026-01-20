{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.modules.services.huggingface-cache;
in
{
  options.modules.services.huggingface-cache = {
    enable = mkEnableOption "Hugging Face model caching proxy";

    domain = mkOption {
      type = types.str;
      description = "Domain name for the Hugging Face cache proxy";
    };

    acmeHost = mkOption {
      type = types.str;
      description = "ACME host for SSL certificates";
    };

    cacheDir = mkOption {
      type = types.str;
      default = "/var/cache/huggingface-proxy";
      description = "Directory to store cached Hugging Face models";
    };

    maxSize = mkOption {
      type = types.str;
      default = "500g";
      description = "Maximum size of the cache";
    };

    cacheTime = mkOption {
      type = types.str;
      default = "30d";
      description = "How long to cache models";
    };

    upstream = mkOption {
      type = types.str;
      default = "huggingface.co";
      description = "Upstream Hugging Face hub to proxy (domain:port or just domain)";
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

    resolver = mkOption {
      type = types.nullOr types.str;
      default = "127.0.0.1";
      description = "DNS resolver for nginx (set to null to disable)";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.domain != "";
        message = "modules.services.huggingface-cache: domain must be set";
      }
      {
        assertion = !cfg.enableSSL || cfg.acmeHost != "";
        message = "modules.services.huggingface-cache: acmeHost must be set when SSL is enabled";
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
          keys_zone=hfcache:200m
          max_size=${cfg.maxSize}
          inactive=${cfg.cacheTime}
          use_temp_path=off
          loader_threshold=300
          loader_files=200;

        map $status $hf_cache_header {
          200     "public";
          302     "public";
          default "no-cache";
        }
      '';

      virtualHosts.${cfg.domain} = {
        forceSSL = mkDefault cfg.enableSSL;
        useACMEHost = mkIf cfg.enableSSL (mkDefault cfg.acmeHost);

        extraConfig = ''
          ${optionalString (cfg.resolver != null) "resolver ${cfg.resolver} valid=30s ipv6=off;"}
          client_max_body_size 0;
        '';

        locations =
          let
            cached = {
              proxyPass = "${cfg.upstreamProtocol}://${cfg.upstream}";
              recommendedProxySettings = false;
              extraConfig = ''
                proxy_set_header Host ${cfg.upstream};
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_set_header Authorization $http_authorization;

                proxy_cache_key $scheme$proxy_host$uri$args$http_authorization;

                proxy_cache hfcache;
                proxy_cache_valid 200 301 302 307 ${cfg.cacheTime};
                proxy_cache_valid any 10m;
                proxy_cache_use_stale error timeout http_500 http_502 http_503 http_504 updating;
                proxy_cache_revalidate on;
                proxy_cache_lock on;
                proxy_cache_lock_timeout 5m;
                proxy_cache_lock_age 5m;
                proxy_cache_background_update on;

                proxy_ignore_headers Cache-Control Expires;
                proxy_hide_header Cache-Control;
                proxy_hide_header Pragma;

                add_header X-Cache-Status $upstream_cache_status always;
                add_header Cache-Control "public, max-age=31536000" always;

                chunked_transfer_encoding on;
                client_max_body_size 0;
                proxy_http_version 1.1;
                proxy_request_buffering off;
              '';
            };
          in
          {
            "/" = cached;
            "~ ^/.*/(resolve|tree|blob)/" = cached;
            "~ ^/.*/raw/" = cached;
            "/api/" = cached;
          };
      };
    };
  };
}
