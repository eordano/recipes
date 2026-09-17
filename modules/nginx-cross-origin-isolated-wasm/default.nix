{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.services.nginx;

  coiHeaders =
    app:
    ''
      add_header Strict-Transport-Security "${app.hstsHeader}" always;
      add_header X-Frame-Options "SAMEORIGIN" always;
      add_header X-Content-Type-Options "nosniff" always;
      add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    ''
    + lib.optionalString (app.contentSecurityPolicy != null) ''
      add_header Content-Security-Policy "${app.contentSecurityPolicy}" always;
    ''
    + app.extraSecurityHeaders
    + ''
      add_header Cross-Origin-Opener-Policy   "same-origin"           always;
      add_header Cross-Origin-Embedder-Policy "${app.embedderPolicy}" always;
      add_header Cross-Origin-Resource-Policy "${app.resourcePolicy}"  always;
    '';

  sanitize = s: lib.replaceStrings [ "/" "-" "." ] [ "_" "_" "_" ] (lib.removePrefix "/" s);

  mkAppLocations =
    mount: app:
    let
      mountNoTrail = lib.removeSuffix "/" mount;
      mountSlash = mountNoTrail + "/";
      varName = "coi_pinned_${sanitize mountNoTrail}";

      immutableBlock = lib.optionalString (app.immutablePaths != [ ]) (
        let
          alt = lib.concatStringsSep "|" app.immutablePaths;
        in
        ''
          location ~ ^${mountSlash}(?<${varName}>(?:${alt})/.+)$ {
              alias ${app.root}/''$${varName};
              brotli_static on;
              disable_symlinks off;
              add_header Cache-Control "public, max-age=31536000, immutable" always;
              ${coiHeaders app}
          }
        ''
      );

      fallback = if app.spaFallback then "${mountSlash}${app.index}" else "=404";

      apiLocs = lib.mapAttrs' (
        publicPath: upstream: lib.nameValuePair "= ${publicPath}" { proxyPass = upstream; }
      ) app.apiProxy;
    in
    apiLocs
    // lib.optionalAttrs (mountNoTrail != "") {
      "= ${mountNoTrail}" = {
        extraConfig = "return 308 ${mountSlash};";
      };
    }
    // {
      ${mountSlash} = {
        alias = "${app.root}/";
        inherit (app) index;
        extraConfig = ''
          brotli_static on;
          disable_symlinks off;
          try_files $uri $uri/ ${fallback};
          # Stable-name entrypoints (index.html, a stable-named loader): store
          # but revalidate every use. Anything cacheable-by-name would pin a
          # browser to a dead build after a redeploy. Content-hashed assets opt
          # back into immutable caching in the nested block below.
          add_header Cache-Control "no-cache" always;
          ${coiHeaders app}
          ${immutableBlock}
        '';
      };
    };

  appSubmodule = lib.types.submodule {
    options = {
      root = lib.mkOption {
        type = lib.types.oneOf [
          lib.types.package
          lib.types.path
          lib.types.str
        ];
        description = ''
          The built SPA bundle: a directory (store path or derivation) with
          index.html at its top and content-hashed assets underneath. Ship it
          with brotli precompressed sidecars (foo.js + foo.js.br) so
          `brotli_static` can serve the .br to clients that accept it.
        '';
      };
      index = lib.mkOption {
        type = lib.types.str;
        default = "index.html";
        description = "The entrypoint filename, served no-cache and used as the SPA fallback.";
      };
      immutablePaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "assets"
          "chunks"
        ];
        description = ''
          First-path-segment names, under the mount, whose files are
          content-hashed and therefore safe to cache immutably for a year. Each
          becomes an alternative in the nested immutable-assets regex. Leave
          empty and every file is served no-cache (correct but cold).
        '';
      };
      embedderPolicy = lib.mkOption {
        type = lib.types.enum [
          "require-corp"
          "credentialless"
        ];
        default = "credentialless";
        description = ''
          Cross-Origin-Embedder-Policy value. Both grant `crossOriginIsolated`
          (and thus SharedArrayBuffer). `require-corp` forces every cross-origin
          subresource to carry CORP/CORS or the load fails; `credentialless`
          instead sends such requests without credentials, which is far more
          forgiving for an app that fetches from third-party origins.
        '';
      };
      resourcePolicy = lib.mkOption {
        type = lib.types.enum [
          "same-origin"
          "same-site"
          "cross-origin"
        ];
        default = "same-origin";
        description = ''
          Cross-Origin-Resource-Policy value -- governs who may embed THIS app's
          own responses. Keep `same-origin` for a standalone app; set
          `cross-origin` only if another origin must embed these bytes.
        '';
      };
      hstsHeader = lib.mkOption {
        type = lib.types.str;
        default = "max-age=63072000; includeSubDomains";
        example = "$hsts_header";
        description = ''
          HSTS policy re-emitted on the app's routes (a location add_header drops
          the server-level HSTS, so it must be repeated). Set to `$hsts_header`
          to reuse nginx-opinionated-defaults' http-block map.
        '';
      };
      contentSecurityPolicy = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "default-src 'self' https: data: blob:; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; worker-src 'self' blob:";
        description = ''
          Optional CSP for the app's routes, usually WIDER than the site default:
          a WASM engine typically needs `wasm-unsafe-eval` (or `unsafe-eval` if
          it builds scene code with `new Function`), `worker-src blob:` for its
          worker threads, and `blob:`/`data:` in connect/img/media. Null omits
          the header on these routes.
        '';
      };
      extraSecurityHeaders = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Extra add_header lines re-emitted inside every location for this mount (they too would otherwise be dropped).";
      };
      spaFallback = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Route unknown paths to the entrypoint (client-side routing). Off makes them 404.";
      };
      apiProxy = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          "/app/api" = "http://127.0.0.1:8080/v1";
        };
        description = ''
          Exact-match strip-prefix proxies for the app's same-origin API. Each
          entry becomes `location = <path> { proxy_pass <upstream>; }`. The `=`
          makes the match exact and the URI on the upstream makes nginx forward
          exactly that URI, stripping the public prefix.
        '';
      };
    };
  };

  vhostOptions =
    { config, ... }:
    {
      options.crossOriginIsolatedApps = lib.mkOption {
        type = lib.types.attrsOf appSubmodule;
        default = { };
        description = ''
          Cross-origin-isolated WASM SPA mounts on this vhost, keyed by URL path
          (e.g. "/app" or "/"). Each generates a redirect, the served mount with
          COOP/COEP/CORP + HSTS re-emission and the no-cache/immutable cache
          split, and optional strip-prefix API proxies.
        '';
      };
      config.locations = lib.mkMerge (lib.mapAttrsToList mkAppLocations config.crossOriginIsolatedApps);
    };

  anyApp = lib.any (vh: vh.crossOriginIsolatedApps or { } != { }) (lib.attrValues cfg.virtualHosts);
in
{
  options.services.nginx.virtualHosts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule vhostOptions);
  };

  config = lib.mkIf anyApp {
    services.nginx.additionalModules = [ pkgs.nginxModules.brotli ];
    services.nginx.recommendedBrotliSettings = lib.mkDefault true;
  };
}
