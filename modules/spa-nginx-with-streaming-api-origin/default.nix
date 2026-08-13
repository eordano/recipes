{
  config,
  lib,
  ...
}:

let
  cfg = config.services.spaStreamingSites;

  mkStreamingConfig = timeout: ''
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_cache off;
    gzip off;
    proxy_read_timeout ${timeout};
    proxy_send_timeout ${timeout};
    send_timeout ${timeout};
    proxy_set_header X-Accel-Buffering no;
  '';

  upstreamModule = lib.types.submodule (
    { ... }:
    {
      options = {
        upstream = lib.mkOption {
          type = lib.types.str;
          example = "http://127.0.0.1:8080";
          description = ''
            Where this API prefix is proxied. A scheme + host + port, as nginx's
            `proxy_pass` wants it. Use a loopback address for a co-located
            backend; the point of this recipe is that the browser never sees it.
          '';
        };
        websockets = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Set the `Upgrade`/`Connection` headers so a websocket handshake is
            proxied through (nginx `proxyWebsockets`). Leave false for plain SSE
            or chunked long-poll -- those need HTTP/1.1 and buffering off (both
            applied unconditionally) but NOT the upgrade dance.
          '';
        };
        streaming = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Apply the streaming proxy config (buffering off, long timeouts). On
            by default: this module exists for streaming origins. Turn it off
            only for a plain request/response JSON endpoint that shares the vhost
            and actually benefits from buffering.
          '';
        };
        extraConfig = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Extra nginx directives appended to this location (e.g. an auth header include).";
        };
      };
    }
  );

  siteModule = lib.types.submodule (
    { name, ... }:
    {
      options = {
        serverName = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "The vhost server_name. Defaults to the attribute name.";
        };
        root = lib.mkOption {
          type = lib.types.either lib.types.path lib.types.package;
          example = lib.literalExpression "pkgs.myApp";
          description = ''
            The built SPA: a directory containing index.html and the hashed
            asset bundle. This is the output of the BUILD half -- see
            packages/js-workspace-package for turning a pnpm/npm workspace into
            exactly this directory.
          '';
        };
        index = lib.mkOption {
          type = lib.types.str;
          default = "index.html";
          description = "The SPA entry document the fallback serves for client-side routes.";
        };
        apiUpstreams = lib.mkOption {
          type = lib.types.attrsOf upstreamModule;
          default = { };
          example = lib.literalExpression ''
            {
              "/api/".upstream = "http://127.0.0.1:8080";
              "/ws/" = { upstream = "http://127.0.0.1:8080"; websockets = true; };
            }
          '';
          description = ''
            API path prefixes to reverse-proxy, keyed by the location prefix
            (with its trailing slash). Each becomes a `^~ <prefix>` location so
            it wins over the SPA fallback AND over any regex location. Order is
            irrelevant: nginx picks the longest matching `^~` prefix.
          '';
        };
        streamingTimeout = lib.mkOption {
          type = lib.types.str;
          default = "1h";
          example = "24h";
          description = ''
            Read/send/client timeout for streaming locations. A live stream can
            sit idle between events for a long time; set this above your longest
            expected gap. There is no way to say "never time out" -- pick a
            generous bound.
          '';
        };
        clientMaxBodySize = lib.mkOption {
          type = lib.types.str;
          default = "10m";
          description = "client_max_body_size for the vhost (raise it if the API accepts large uploads).";
        };
        forceSSL = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Redirect http to https for this vhost (passed through to services.nginx).";
        };
        enableACME = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Obtain a certificate for serverName via ACME (passed through to services.nginx).";
        };
        useACMEHost = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Use an existing (e.g. wildcard) ACME certificate host instead of requesting one per name.";
        };
        default = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Make this the default vhost (nginx `default_server`).";
        };
        extraVirtualHostConfig = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          description = "Extra attributes merged into the generated services.nginx.virtualHosts.<serverName>.";
        };
      };
    }
  );

  mkVhost =
    site:
    let
      apiLocations = lib.mapAttrs' (
        prefix: up:
        lib.nameValuePair "^~ ${prefix}" {
          proxyPass = up.upstream;
          proxyWebsockets = up.websockets;
          extraConfig =
            (lib.optionalString up.streaming (mkStreamingConfig site.streamingTimeout)) + up.extraConfig;
        }
      ) site.apiUpstreams;

      spaLocation = {
        "/" = {
          root = toString site.root;
          tryFiles = "$uri /${site.index}";
        };
      };
    in
    lib.recursiveUpdate {
      inherit (site) forceSSL enableACME default;
      serverName = site.serverName;
      useACMEHost = site.useACMEHost;
      locations = apiLocations // spaLocation;
      extraConfig = ''
        client_max_body_size ${site.clientMaxBodySize};
      '';
    } site.extraVirtualHostConfig;
in
{
  options.services.spaStreamingSites = lib.mkOption {
    type = lib.types.attrsOf siteModule;
    default = { };
    description = ''
      Co-host a static single-page app and a same-origin streaming (SSE /
      websocket) API behind one nginx vhost. Each entry generates one
      `services.nginx.virtualHosts.<serverName>`.
    '';
  };

  config = lib.mkIf (cfg != { }) {
    services.nginx.enable = lib.mkDefault true;

    services.nginx.virtualHosts = lib.mapAttrs' (
      _name: site: lib.nameValuePair site.serverName (mkVhost site)
    ) cfg;
  };
}
