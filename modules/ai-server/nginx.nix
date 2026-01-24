{
  config,
  lib,
  ...
}:
with lib; let
  cfg = config.modules.services.ai-server;

  vllmChatModels = filter (m: m.backend == "vllm") cfg.chatModels;

  # Common proxy config for AI services
  aiProxyConfig = {
    proxyWebsockets = true;
    extraConfig = ''
      proxy_buffering off;
      proxy_request_buffering off;
      proxy_read_timeout 300s;
      proxy_connect_timeout 75s;
      proxy_send_timeout 300s;
      send_timeout 300s;
      client_max_body_size 100M;
    '';
  };

  # SSL settings applied to each vhost
  sslAttrs =
    optionalAttrs cfg.enableSSL {
      enableACME = cfg.useACMEHost == null;
      useACMEHost = mkIf (cfg.useACMEHost != null) cfg.useACMEHost;
    }
    // optionalAttrs cfg.forceSSL {
      forceSSL = true;
    };
in {
  config = mkIf cfg.enable {
    services.nginx = {
      enable = mkDefault true;
      recommendedProxySettings = mkDefault true;

      virtualHosts = {
        # Main domain: LiteLLM API + optional web root
        ${cfg.domain} = sslAttrs // {
          default = mkDefault true;
          locations = {
            "~ ^/(v1|docs|health|openapi.json)" = aiProxyConfig // {
              proxyPass = "http://127.0.0.1:${toString cfg.litellmPort}";
            };
          } // optionalAttrs (cfg.webRoot != null) {
            "/" = {
              root = cfg.webRoot;
              index = "index.html";
              extraConfig = ''
                try_files $uri $uri/ /index.html;
              '';
            };
          };
        };
      }
      # Optional speaches domain
      // optionalAttrs (cfg.speachesDomain != null) {
        ${cfg.speachesDomain} = sslAttrs // {
          locations."/" = aiProxyConfig // {
            proxyPass = "http://127.0.0.1:${toString cfg.speachesPort}/";
          };
        };
      }
      # Optional vLLM direct access domain
      // optionalAttrs (cfg.vllmDomain != null && vllmChatModels != []) {
        ${cfg.vllmDomain} = sslAttrs // {
          locations."/" = aiProxyConfig // {
            proxyPass = "http://127.0.0.1:${toString (head vllmChatModels).vllm.port}/";
          };
        };
      };
    };
  };
}
