# Signed HTTPS binary cache for a NixOS store.
#
# Exposes the local Nix store as a *signed* binary cache over HTTPS
# (nix-serve-ng behind nginx) so other machines can add this host to their
# `nix.settings.substituters` and pull pre-built derivations instead of
# recompiling.
#
# The interesting part is the caching policy: store paths are content
# hashes, so a path that exists never changes. That makes it safe to serve
# every response with `Cache-Control: public, immutable` and a year-long
# `proxy_cache_valid`, letting any downstream proxy/CDN hold responses
# indefinitely. `secretKeyFile` is what makes those cached responses
# trustworthy: nix-serve signs every narinfo, and `require-sigs` clients
# accept the cache only if the matching public key is in their
# `trusted-public-keys`.
#
# Usage:
#   imports = [ ./signed-binary-cache ];
#   services.signedBinaryCache = {
#     enable        = true;
#     domain        = "cache.example.com";
#     secretKeyFile = "/run/secrets/cache-priv-key.pem";
#   };
#
# Generate the signing keypair once (keep the private half secret, publish
# the public line so clients can trust the cache):
#   nix-store --generate-binary-cache-key cache.example.com-1 \
#     cache-priv-key.pem cache-pub-key.pem
#
# Clients then add:
#   nix.settings.substituters        = [ "https://cache.example.com" ];
#   nix.settings.trusted-public-keys = [ "cache.example.com-1:<contents of cache-pub-key.pem>" ];

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.services.signedBinaryCache;
in
{
  options.services.signedBinaryCache = {
    enable = mkEnableOption "signed nix-serve-ng binary cache server";

    domain = mkOption {
      type = types.str;
      example = "cache.example.com";
      description = "Public domain name the binary cache is served on.";
    };

    port = mkOption {
      type = types.port;
      default = 5000;
      description = "Loopback port nix-serve listens on (proxied by nginx).";
    };

    bindAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = ''
        Address the plaintext nix-serve backend binds to. Defaults to
        loopback, because nginx is the only intended client and the backend
        speaks unencrypted HTTP; upstream `services.nix-serve.bindAddress`
        defaults to `0.0.0.0`, which exposes it on every interface (including
        ones your firewall trusts wholesale, e.g. a VPN interface listed in
        `networking.firewall.trustedInterfaces`).

        Widen it only if something other than the local nginx must reach the
        backend directly.
      '';
    };

    secretKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/cache-priv-key.pem";
      description = ''
        Path to the private signing key. When set, nix-serve signs every
        narinfo, and clients with `require-sigs = true` (the Nix default)
        will trust this cache once the matching public key is in their
        `trusted-public-keys`. Leave null only for a cache clients trust by
        other means (e.g. it is not exposed publicly).

        This should be a secret delivered out-of-band (agenix, sops-nix, a
        systemd credential, …) — never a path inside the world-readable Nix
        store.
      '';
    };

    enableACME = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether this module should request an ACME (Let's Encrypt)
        certificate for `domain`. Set false if you terminate TLS elsewhere
        or manage the cert yourself via `useACMEHost`.
      '';
    };

    useACMEHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "example.com";
      description = ''
        Reuse an existing ACME certificate (e.g. a wildcard) keyed by this
        host instead of requesting a dedicated one. Mutually exclusive with
        `enableACME`.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.nix-serve = {
      enable = true;
      inherit (cfg) port secretKeyFile bindAddress;
      # nix-serve-ng is the Haskell rewrite: a faster, drop-in replacement for
      # the original Perl nix-serve. The nixpkgs default for
      # `services.nix-serve.package` is still the original, so opt in here.
      # mkDefault lets you swap back with
      # `services.nix-serve.package = pkgs.nix-serve;`.
      package = lib.mkDefault pkgs.nix-serve-ng;
    };

    services.nginx = {
      enable = true;
      recommendedProxySettings = lib.mkDefault true;
      virtualHosts.${cfg.domain} = {
        forceSSL = true;
        enableACME = cfg.enableACME && cfg.useACMEHost == null;
        useACMEHost = cfg.useACMEHost;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          proxyWebsockets = false;
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # Store paths are immutable content hashes: a path that exists
            # never changes. So any 200 can be cached, downstream, for a
            # year — and told to browsers/CDNs it is immutable.
            proxy_cache_valid 200 365d;
            expires max;
            add_header Cache-Control "public, immutable";
          '';
        };
      };
    };
  };
}
