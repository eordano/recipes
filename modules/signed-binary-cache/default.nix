{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    ;
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
        systemd credential, ...) -- never a path inside the world-readable Nix
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
      package = lib.mkDefault pkgs.nix-serve-ng;
    };

    services.nginx = {
      enable = true;
      recommendedProxySettings = lib.mkDefault true;
      virtualHosts.${cfg.domain} = {
        forceSSL = true;
        enableACME = cfg.enableACME && cfg.useACMEHost == null;
        inherit (cfg) useACMEHost;
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
            # year -- and told to browsers/CDNs it is immutable.
            proxy_cache_valid 200 365d;
            expires max;
            add_header Cache-Control "public, immutable";
          '';
        };
      };
    };
  };
}
