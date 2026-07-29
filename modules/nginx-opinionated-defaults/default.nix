# nginx-opinionated-defaults
#
# A NixOS module that layers opinionated defaults onto `services.nginx`, plus a
# handful of per-virtual-host knobs. Drop it into `imports` and it augments the
# stock nginx module in place (it does not replace it).
#
# What it gives you:
#   * A custom access-log format that captures the `Host` header. The stock
#     `combined` format omits it, which blinds any multi-vhost log analysis
#     (goaccess, fail2ban, ad-hoc grep) because every request looks like it hit
#     the same server.
#   * HSTS on every https response, defined once as an http-block `map`.
#   * Custom "recommended" TLS session/cipher settings, kept as our own block
#     rather than upstream's `recommendedTlsSettings` so this module's cipher
#     choices stay decoupled from upstream churn. Kept at parity with upstream's
#     post-quantum key-exchange group (`X25519MLKEM768`).
#   * Real-client-IP extraction from Cloudflare's officially published IP-range
#     list, both globally and per-vhost.
#   * Per-vhost overrides: `proxyTimeout`, `clientMaxBodySize`, `extraSecurity`
#     (a baseline security-header set, off by default because the aggressive
#     COEP header breaks apps that embed cross-origin resources, e.g. Immich).
#
# This module has no private wiring. The only thing you must supply from outside
# is a path to Cloudflare's IP-range file if you want the real-IP feature (see
# `cloudflareIPRangesFile` below and the README).

{ lib, config, pkgs, ... }:
let
  cfg = config.services.nginx;

  # Baseline security headers prepended to any vhost that opts into
  # `extraSecurity`. Two traps live here:
  #   * `$hsts_header` is an nginx *variable*; it must be defined in the http
  #     block (see `enableHSTSEverywhere`) or nginx refuses to start.
  #   * `Cross-Origin-Embedder-Policy: require-corp` is aggressive: it breaks any
  #     page that loads cross-origin subresources without CORP/CORS headers.
  #     That is exactly why `extraSecurity` is off by default per vhost — turn it
  #     on only for vhosts you know are self-contained.
  defaultSecurityHeaders = ''
    add_header Strict-Transport-Security $hsts_header;
    add_header 'Referrer-Policy' 'origin-when-cross-origin';
    add_header X-Content-Type-Options nosniff;
    add_header Cross-Origin-Opener-Policy "same-origin";
    add_header Cross-Origin-Embedder-Policy "require-corp";
  '';

  # Turn Cloudflare's published IP-range list (one CIDR per line) into a block of
  # `set_real_ip_from` directives plus the CF-Connecting-IP wiring. Emits nothing
  # if no file was configured (guarded by an assertion below when a feature that
  # needs it is enabled).
  cloudflareRealIPConfig = lib.optionalString (cfg.cloudflareIPRangesFile != null) ''
    ${builtins.concatStringsSep "\n" (
      map (ip: "set_real_ip_from ${ip};") (
        lib.splitString "\n" (
          lib.removeSuffix "\n" (builtins.readFile cfg.cloudflareIPRangesFile)
        )
      )
    )}
    real_ip_header CF-Connecting-IP;
    real_ip_recursive on;
  '';

  # Any per-vhost use of the Cloudflare real-IP feature also needs the file.
  anyVhostUsesCloudflareRealIP =
    lib.any (vh: vh.useCloudflareRealIP) (lib.attrValues cfg.virtualHosts);

  vhostOptions =
    { config, ... }:
    {
      options = {
        safeProxyParameters = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Add proxy parameters that are safe for internal use (only applied when extraSecurity is on).";
        };
        extraSecurity = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable the baseline security-header set. Off by default because the aggressive COEP header can break apps that embed cross-origin resources (e.g. Immich).";
        };
        useCloudflareRealIP = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Extract the real client IP from Cloudflare's CF-Connecting-IP header for this vhost. Requires services.nginx.cloudflareIPRangesFile.";
        };
        proxyTimeout = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Override the proxy connect/send/read timeout for this vhost.";
          example = "60s";
          apply =
            value:
            if value == null then
              null
            else
              assert lib.strings.match "^[0-9]+[smhd]?$" value != null;
              value;
        };
        clientMaxBodySize = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Override client_max_body_size for this vhost.";
          example = "100m";
          apply =
            value:
            if value == null then
              null
            else
              assert lib.strings.match "^[0-9]+[kmgtKMGT]?$" value != null;
              value;
        };
      };
      config = {
        extraConfig = lib.mkMerge [
          (lib.mkIf config.extraSecurity (
            cfg.securityHeaders
            + (
              if config.safeProxyParameters then
                ''
                  client_max_body_size 500m;
                  proxy_read_timeout 30;
                  proxy_connect_timeout 30;
                  proxy_send_timeout 30;
                  proxy_headers_hash_max_size 4096;
                ''
              else
                ""
            )
          ))
          (lib.mkIf config.useCloudflareRealIP cloudflareRealIPConfig)
          (lib.mkIf (config.proxyTimeout != null) ''
            proxy_connect_timeout ${config.proxyTimeout};
            proxy_send_timeout ${config.proxyTimeout};
            proxy_read_timeout ${config.proxyTimeout};
          '')
          (lib.mkIf (config.clientMaxBodySize != null) ''
            client_max_body_size ${config.clientMaxBodySize};
          '')
        ];
      };
    };
in
{
  options.services.nginx = {
    defaultTweaks = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Apply the opinionated global defaults (gzip/optimisation/proxy on, upstream recommendedTlsSettings off in favour of customRecommendedTlsSettings, hardened ciphers).";
    };
    enableHSTSEverywhere = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Define the \$hsts_header map so every https response carries HSTS. Required if any vhost uses extraSecurity, which references \$hsts_header.";
    };
    hstsHeader = lib.mkOption {
      type = lib.types.str;
      default = "max-age=31536000; includeSubdomains; preload";
      description = "HSTS policy value sent on https responses when enableHSTSEverywhere is on. The default is hard to undo: includeSubdomains commits every current and future subdomain to HTTPS-only, and preload asserts eligibility for browsers' built-in preload list (removal takes months). Drop those tokens here if you cannot commit to that.";
    };
    extraLogBodies = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Load the nginx Lua module (for request/response body logging in your own snippets). Debug aid, off by default.";
    };
    customRecommendedTlsSettings = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Apply this module's own TLS session/cipher settings (kept at parity with upstream recommendedTlsSettings, including its post-quantum key-exchange group) instead of upstream's recommendedTlsSettings block.";
    };
    enableCloudflareRealIP = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Globally extract the real client IP from Cloudflare's CF-Connecting-IP header. Requires cloudflareIPRangesFile.";
    };
    cloudflareIPRangesFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to Cloudflare's published IP-range list, one CIDR per line (both
        v4 and v6 are accepted). Wire the upstream repo as a flake input and
        point at its raw list, e.g.
        `inputs.cloudflare-ip-ranges + "/lists/cloudflare_ips_raw.txt"`.
        Required when any Cloudflare real-IP feature is enabled.
      '';
      example = lib.literalExpression ''inputs.cloudflare-ip-ranges + "/lists/cloudflare_ips_raw.txt"'';
    };
    securityHeaders = lib.mkOption {
      type = lib.types.lines;
      default = defaultSecurityHeaders;
      description = "The header block emitted by a vhost's extraSecurity. Override to change or extend the baseline set.";
    };
    virtualHosts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule vhostOptions);
    };
  };

  config = {
    assertions = [
      {
        assertion =
          (cfg.enableCloudflareRealIP || anyVhostUsesCloudflareRealIP)
          -> (cfg.cloudflareIPRangesFile != null);
        message = "services.nginx: a Cloudflare real-IP feature is enabled but cloudflareIPRangesFile is unset.";
      }
    ];

    services.nginx = lib.mkMerge [
      (lib.mkIf cfg.defaultTweaks {
        recommendedGzipSettings = lib.mkDefault true;
        recommendedOptimisation = lib.mkDefault true;
        recommendedProxySettings = lib.mkDefault true;
        # Disabled on purpose: we supply our own TLS block (customRecommendedTlsSettings)
        # kept at parity with this block, decoupled from upstream churn.
        recommendedTlsSettings = lib.mkDefault false;

        sslCiphers = "AES256+EECDH:AES256+EDH:!aNULL";
      })

      {
        additionalModules = lib.mkIf cfg.extraLogBodies [ pkgs.nginxModules.lua ];

        commonHttpConfig = lib.mkIf cfg.enableHSTSEverywhere ''
          map $scheme $hsts_header {
              https   "${cfg.hstsHeader}";
          }
        '';

        appendHttpConfig = lib.mkMerge [
          # mkBefore so the custom log_format is defined before anything that
          # might reference it, and so our access_log wins.
          (lib.mkBefore ''
            log_format combined_with_host '$remote_addr - $remote_user [$time_local] '
                '"$request" $status $body_bytes_sent '
                '"$http_referer" "$http_user_agent" "$host"';
            access_log /var/log/nginx/access.log combined_with_host;
          '')
          ''
            proxy_headers_hash_max_size 4096;
            proxy_headers_hash_bucket_size 1024;
          ''
          (lib.mkIf cfg.customRecommendedTlsSettings ''
            ssl_conf_command Groups "X25519MLKEM768:X25519:P-256:P-384";
            ssl_session_timeout 1d;
            ssl_session_cache shared:SSL:10m;
            ssl_session_tickets off;
            ssl_prefer_server_ciphers off;
          '')
          (lib.mkIf cfg.enableCloudflareRealIP cloudflareRealIPConfig)
        ];
      }
    ];
  };
}
