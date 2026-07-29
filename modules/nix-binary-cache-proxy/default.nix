# nix-binary-cache-proxy
#
# A pure-nginx caching proxy in front of cache.nixos.org (or any binary cache).
# No nix-serve, no separate daemon — just nginx's own `proxy_cache_path`.
#
# Point every machine's `nix.settings.substituters` at this host and:
#   - the same NAR is fetched from the WAN once, then served from local disk;
#   - builds keep working while the upstream cache is unreachable
#     (served stale via `proxy_cache_use_stale`).
#
# Drop-in usage:
#   imports = [ ./nix-binary-cache-proxy ];
#   modules.services.nix-cache = {
#     enable   = true;
#     domain   = "cache.example.com";
#     acmeHost = "cache.example.com";   # a services.nginx / security.acme cert
#   };
#
# Then on clients:
#   nix.settings.substituters      = [ "https://cache.example.com" ];
#   nix.settings.trusted-public-keys = [ "cache.nixos.org-1:6NCHdD..." ];
# (Keep the upstream's public key — this proxy passes NARs through verbatim,
#  it does not re-sign them.)

{ config, lib, ... }:

with lib;

let
  cfg = config.modules.services.nix-cache;
in
{
  options.modules.services.nix-cache = {
    enable = mkEnableOption "pure-nginx Nix binary cache proxy";

    domain = mkOption {
      type = types.str;
      example = "cache.example.com";
      description = "Virtual host name the proxy is served under.";
    };

    acmeHost = mkOption {
      type = types.str;
      example = "cache.example.com";
      description = ''
        `security.acme` certificate name to use for TLS (`useACMEHost`).
        Configure the cert itself via `security.acme.certs.<name>` elsewhere.
      '';
    };

    upstreamEndpoint = mkOption {
      type = types.str;
      default = "cache.nixos.org";
      description = "Upstream binary cache host to proxy and cache.";
    };

    verifyUpstreamTls = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Verify the upstream cache's TLS certificate against the system CA
        bundle when filling the cache. Defense-in-depth on top of the Nix
        clients' signature checks. Disable only for an upstream with a
        certificate the system bundle can't validate (e.g. a self-signed
        internal cache).
      '';
    };

    cacheDir = mkOption {
      type = types.str;
      default = "/var/cache/nix-cache-proxy";
      description = "Directory nginx stores the cached NARs / narinfo in.";
    };

    maxCacheSize = mkOption {
      type = types.str;
      default = "50g";
      example = "800g";
      description = ''
        Upper bound on the on-disk cache (`proxy_cache_path max_size`).
        nginx evicts least-recently-used entries above this.
      '';
    };

    cacheLockTimeout = mkOption {
      type = types.str;
      default = "60s";
      example = "0s";
      description = ''
        `proxy_cache_lock_timeout`: how long a request may wait for another
        request that is already filling the same cache entry.

        This is what makes `proxy_cache_lock on` actually collapse a cold-miss
        herd. Waiters are released as soon as the entry lands in the cache, so
        for a typical NAR the wait is short; if the fill is still running when
        the timeout expires, the waiters are passed straight through to the
        upstream and their responses are NOT cached — i.e. the herd is no
        longer collapsed.

        Set this to `"0s"` to opt out of waiting entirely (every concurrent
        cold-miss request goes straight to the upstream, uncached) — lower
        worst-case latency, no request collapsing.
      '';
    };

    resolver = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        DNS resolver nginx uses to re-resolve the upstream host at request
        time. Must be a working resolver reachable from the box (e.g. a local
        stub resolver, or your LAN DNS). Required because the upstream is held
        in an nginx variable (see notes) rather than baked in at startup.
      '';
    };

    websiteDir = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = literalExpression "./landing";
      description = ''
        Optional static directory served at `/`. Any 404 there falls through
        to the upstream cache proxy. When null, `/` proxies straight to the
        upstream. `/nix-cache-info` is always pinned to the proxy regardless.
      '';
    };

    extraHeaders = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Extra nginx directives (e.g. security `add_header` lines) injected
        into every served location. Kept as an option so a standalone deploy
        can bolt on its own header policy without patching the module.
      '';
    };
  };

  config = mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.cacheDir} 0755 nginx nginx -"
    ];
    systemd.services.nginx.serviceConfig.ReadWritePaths = [ cfg.cacheDir ];

    services.nginx = {
      enable = lib.mkDefault true;
      virtualHosts."${cfg.domain}" = {
        forceSSL = true;
        useACMEHost = cfg.acmeHost;

        # The upstream is placed in a *variable* so nginx re-resolves it via
        # `resolver` on every request. If you write the host literally in
        # `proxy_pass`, nginx resolves it once at startup and freezes that IP
        # until the next config reload — which breaks when a CDN-backed cache
        # rotates addresses.
        extraConfig = ''
          resolver ${cfg.resolver} valid=30s ipv6=off;
          set $upstream_endpoint ${cfg.upstreamEndpoint};
        '';

        locations =
          let
            cached = {
              proxyPass = "https://$upstream_endpoint";
              recommendedProxySettings = false;
              extraConfig = ''
                ${optionalString cfg.verifyUpstreamTls ''
                  proxy_ssl_verify              on;
                  proxy_ssl_verify_depth        5;
                  proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
                  proxy_ssl_server_name         on;
                  proxy_ssl_name                $upstream_endpoint;
                ''}
                proxy_set_header           Host $upstream_endpoint;
                add_header                 Cache-Control $nix_cache_header always;
                proxy_cache                nix_cache_proxy;
                proxy_cache_valid          200 302 60d;
                proxy_pass_request_headers off;
                expires                    max;

                # Collapse a thundering herd: only one request populates a
                # given key at a time; the rest wait (or serve stale) instead
                # of all stampeding the upstream for the same NAR. The wait is
                # bounded by cacheLockTimeout — at 0s there is no waiting at
                # all and the lock collapses nothing on a cold miss.
                proxy_cache_lock           on;
                proxy_cache_lock_timeout   ${cfg.cacheLockTimeout};
                proxy_cache_lock_age       300s;
                proxy_cache_use_stale      updating;
                ${cfg.extraHeaders}
              '';
            };
          in
          (optionalAttrs (cfg.websiteDir != null) {
            # Static-first: serve the site from disk, and only on a 404 fall
            # through to the upstream proxy.
            "/" = {
              root = cfg.websiteDir;
              extraConfig = ''
                expires max;
                add_header Cache-Control $nix_cache_header always;
                error_page 404 = @fallback;
                ${cfg.extraHeaders}
              '';
            };
            "@fallback" = cached;
          })
          // optionalAttrs (cfg.websiteDir == null) {
            "/" = cached;
          }
          // {
            # Pin the cache-info endpoint to the proxy so Nix clients always
            # get a valid response even if the static dir shadows the name.
            "= /nix-cache-info" = cached;
          };
      };

      appendHttpConfig = lib.mkAfter ''
        proxy_cache_path ${cfg.cacheDir} levels=1:2 keys_zone=nix_cache_proxy:200m max_size=${cfg.maxCacheSize} inactive=30d use_temp_path=off;

        # Whole-cache mirroring pushes GBs of large NARs through nginx.
        # directio makes files >8 KiB bypass the page cache on the way out so
        # they don't evict everything else the box has hot; AIO + wide output
        # buffers keep those large files streaming instead of stalling.
        open_file_cache      max=512;
        aio                  on;
        directio             8192;
        output_buffers       12 512k;

        # Only cache-hittable statuses advertise as publicly cacheable.
        map $status $nix_cache_header {
          200     "public";
          302     "public";
          default "no-cache";
        }
      '';
    };
  };
}
