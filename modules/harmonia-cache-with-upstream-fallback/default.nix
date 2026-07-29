# Harmonia binary cache with a transparent, disk-cached upstream fallback.
#
# One substituter URL covers BOTH this machine's own /nix/store (served and
# signed by harmonia) AND an on-disk-cached copy of an upstream substituter
# (cache.nixos.org by default). A 404 from harmonia falls through to an
# nginx proxy_cache'd upstream: the first peer to request a path warms the
# local disk cache, and every subsequent peer -- plus this builder itself --
# then hits local disk instead of the WAN.
#
# Import into a NixOS host, then set:
#   modules.services.harmonia.enable = true;
#   modules.services.harmonia.domain = "cache.example.com";
#   modules.services.harmonia.acmeHost = "cache.example.com";
#   modules.services.harmonia.signKeyFile = "/run/secrets/cache-priv-key";
#   modules.services.harmonia.upstreamFallback.enable = true;
#
# Generate the signing key once with:
#   nix-store --generate-binary-cache-key cache.example.com-1 \
#     cache-priv-key.pem cache-pub-key.pem
# Keep the private half out of the store (agenix / sops / a systemd cred /
# any out-of-band path) and hand its path to signKeyFile. Publish the public
# half to consumers as trusted-public-keys.

{
  config,
  lib,
  ...
}:
with lib;
let
  cfg = config.modules.services.harmonia;
  fb = cfg.upstreamFallback;
in
{
  options.modules.services.harmonia = {
    enable = mkEnableOption "Harmonia: Rust-based Nix binary cache server";

    domain = mkOption {
      type = types.str;
      example = "cache.example.com";
      description = "Public domain name (nginx vhost) for the binary cache.";
    };

    acmeHost = mkOption {
      type = types.str;
      example = "cache.example.com";
      description = ''
        ACME host whose certificate fronts the cache. Usually equal to
        `domain`; kept separate so you can share a wildcard/SAN cert.
      '';
    };

    signKeyFile = mkOption {
      type = types.path;
      example = "/run/secrets/cache-priv-key";
      description = ''
        Path to the ed25519 secret signing key, generated with
        `nix-store --generate-binary-cache-key`. Provide it out of band
        (agenix, sops-nix, a systemd credential, ...) -- never in the store.
        Must be readable by the harmonia service user.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 5000;
      description = "Port harmonia listens on (loopback only; nginx fronts it).";
    };

    workers = mkOption {
      type = types.int;
      default = 16;
      description = "Number of harmonia worker threads.";
    };

    priority = mkOption {
      type = types.int;
      default = 30;
      description = ''
        Substituter priority advertised in /nix-cache-info. Lower wins;
        cache.nixos.org is 40, so 30 makes this cache preferred.
      '';
    };

    upstreamFallback = {
      enable = mkEnableOption ''
        falling through to an nginx-cached upstream substituter on 404 from
        harmonia. Consumers then see ONE URL covering both this machine's
        local /nix/store AND cached upstream NARs: the first peer to fetch a
        path warms the on-disk cache, subsequent peers (and this host) hit
        local disk instead of the WAN
      '';

      endpoint = mkOption {
        type = types.str;
        default = "cache.nixos.org";
        description = "Upstream substituter host to fall back to.";
      };

      cacheDir = mkOption {
        type = types.str;
        default = "/var/cache/nix-cache";
        description = ''
          Directory for the nginx proxy_cache disk store. Point this at a
          filesystem with plenty of room -- it holds full NARs of everything
          any peer has ever pulled through the fallback.
        '';
      };

      maxCacheSize = mkOption {
        type = types.str;
        default = "100g";
        description = "proxy_cache_path max_size (nginx evicts past this).";
      };

      resolver = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "127.0.0.53";
        description = ''
          DNS resolver nginx should use to re-resolve `endpoint` at request
          time, and the only way to get periodic re-resolution at all.

          When null (the default) `endpoint` is written literally into
          `proxy_pass`, which nginx resolves ONCE at config load and then pins
          for the lifetime of the worker processes. That is fine for a stable
          address and needs no resolver, but a CDN-backed upstream that rotates
          addresses will eventually be proxied to a dead IP until the next
          nginx reload.

          When set, the proxy target is built from an nginx variable instead --
          which is what actually forces per-request resolution -- and a
          `resolver <value> valid=30s` directive is emitted. Point it at a
          resolver that really answers on this box: systemd-resolved's stub is
          `127.0.0.53`, a local unbound/dnsmasq is usually `127.0.0.1`, or use
          your LAN DNS. A wrong value here makes every fallback request fail,
          so it is opt-in rather than a guessed default.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    services.harmonia.cache = {
      enable = true;
      signKeyPaths = [ cfg.signKeyFile ];
      settings = {
        bind = "127.0.0.1:${toString cfg.port}";
        workers = cfg.workers;
        priority = cfg.priority;
      };
    };

    # nginx (not the harmonia user) owns the proxy_cache directory, and the
    # hardened nginx unit needs it whitelisted as writable.
    systemd.tmpfiles.rules = mkIf fb.enable [
      "d ${fb.cacheDir} 0755 nginx nginx -"
    ];
    systemd.services.nginx.serviceConfig.ReadWritePaths = mkIf fb.enable [ fb.cacheDir ];

    # proxy_cache_path must live at http{} scope, not inside a server block.
    services.nginx.appendHttpConfig = mkIf fb.enable (
      lib.mkAfter ''
        proxy_cache_path ${fb.cacheDir} levels=1:2 keys_zone=harmonia_upstream:200m max_size=${fb.maxCacheSize} inactive=60d use_temp_path=off;
      ''
    );

    services.nginx.virtualHosts."${cfg.domain}" = {
      forceSSL = true;
      useACMEHost = cfg.acmeHost;
      # A `resolver` alone does NOT make nginx re-resolve a proxy target: an
      # upstream written literally in proxy_pass is resolved once, at config
      # load. Only a proxy_pass built from a *variable* is resolved per request
      # -- and that form in turn REQUIRES a resolver. So the two are emitted
      # together or not at all.
      extraConfig = mkIf (fb.enable && fb.resolver != null) ''
        resolver ${fb.resolver} valid=30s ipv6=off;
        set $harmonia_upstream ${fb.endpoint};
      '';
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString cfg.port}";
        recommendedProxySettings = false;
        extraConfig = ''
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;

          proxy_cache_valid 200 365d;
          expires max;
          add_header Cache-Control "public, immutable" always;

          # NARs are large and stream-served. Without these three, nginx
          # spools whole objects to disk before forwarding a byte.
          proxy_buffering off;
          proxy_request_buffering off;
          client_max_body_size 0;

          ${optionalString fb.enable ''
            # A store path harmonia does not have returns 404 -- intercept it
            # and re-issue against the cached upstream.
            proxy_intercept_errors on;
            error_page 404 502 504 = @upstream;
          ''}
        '';
      };
      locations."@upstream" = mkIf fb.enable {
        proxyPass = "https://${if fb.resolver == null then fb.endpoint else "$harmonia_upstream"}";
        recommendedProxySettings = false;
        extraConfig = ''
          # Present the upstream's own name (SNI + Host) so its CDN/TLS is happy.
          proxy_set_header Host ${fb.endpoint};
          proxy_pass_request_headers off;
          proxy_ssl_server_name on;
          proxy_ssl_name ${fb.endpoint};

          # Validate the upstream's TLS chain against the system CA bundle.
          # proxy_ssl_server_name/proxy_ssl_name only set SNI -- they do NOT
          # enable verification, which nginx leaves off by default. Without
          # this, an on-path attacker could feed forged bytes into the on-disk
          # proxy_cache. (Nix still signature-verifies every NAR on the
          # consumer, so this is defense-in-depth, not the primary control.)
          proxy_ssl_verify on;
          proxy_ssl_verify_depth 3;
          proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;

          proxy_cache harmonia_upstream;
          proxy_cache_valid 200 302 365d;
          # Cache genuine 404s only briefly, so absent paths don't hammer the
          # upstream on every retry but also don't get pinned as missing.
          proxy_cache_valid 404 1m;
          # Collapse a thundering herd: one request fills the cache entry, the
          # rest wait on it rather than each opening its own upstream fetch.
          proxy_cache_lock on;
          proxy_cache_lock_timeout 0s;
          proxy_cache_lock_age 300s;
          proxy_cache_use_stale updating error timeout;
          add_header X-Cache-Status $upstream_cache_status always;
          expires max;

          proxy_buffering off;
          proxy_request_buffering off;
        '';
      };
    };
  };
}
