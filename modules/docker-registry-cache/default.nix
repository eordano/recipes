# A LAN-wide pull-through cache for Docker/OCI registries, built on
# rpardini/docker-registry-proxy (an HTTPS-intercepting caching proxy).
#
# The whole point of this module is to get the four non-obvious things
# right that make the proxy actually usable:
#
#   1. The proxy mints its OWN CA on first run and intercepts TLS to the
#      upstream registries. Clients must trust that CA or every pull fails
#      with a cert error. We serve it over nginx at /ca.crt so onboarding
#      a new client is a single curl.
#   2. Registry credentials are given as a friendly host:user:pass file,
#      converted to the proxy's AUTH_REGISTRIES form ONLY at preStart into
#      /run (tmpfs) — the expanded secret never lands on persistent disk.
#   3. The CA-export step races the container's cold-boot CA generation,
#      so it polls for both the container and the CA file before copying.
#   4. All nginx buffering is disabled so multi-GB image layers stream
#      through instead of being spooled to disk (and timing out).
#
# Drop it into a NixOS host that already runs Docker + nginx, point your
# LAN Docker daemons at https://<domain>, trust /ca.crt, and pulls are
# cached.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.modules.services.docker-registry-cache;

  # NixOS names oci-container units "<backend>-<container>". With the
  # docker backend and container "docker-registry-proxy" that is
  # "docker-docker-registry-proxy".
  proxyUnit = "docker-docker-registry-proxy";

  # Address nginx must CONNECT to in order to reach the published container
  # port. A bind wildcard is not a connect target, so map it back to loopback
  # (a wildcard publish covers loopback anyway); bracket IPv6 literals, which
  # proxy_pass requires. Anything else is used verbatim, so moving
  # `listenAddress` to a specific interface moves the front end with it.
  proxyUpstream =
    let
      addr = cfg.listenAddress;
    in
    if addr == "" || addr == "0.0.0.0" then
      "127.0.0.1"
    else if addr == "::" || addr == "[::]" then
      "[::1]"
    else if hasInfix ":" addr && !(hasPrefix "[" addr) then
      "[${addr}]"
    else
      addr;
in
{
  options.modules.services.docker-registry-cache = {
    enable = mkEnableOption "pull-through Docker/OCI registry cache proxy";

    domain = mkOption {
      type = types.str;
      example = "docker-cache.example.com";
      description = ''
        FQDN the nginx front-end listens on. Clients point their Docker
        daemon at this host and download the intercept CA from
        https://<domain>/ca.crt.
      '';
    };

    image = mkOption {
      type = types.str;
      default = "ghcr.io/rpardini/docker-registry-proxy:0.6.4";
      description = ''
        Container image reference for rpardini/docker-registry-proxy.
        Pulled normally by the oci-containers backend. Pin a digest or
        tag you trust.
      '';
    };

    cacheDir = mkOption {
      type = types.str;
      default = "/var/lib/docker-registry-cache";
      description = ''
        Base directory for cached layers and the generated CA. Point this
        at a large, ideally dedicated, filesystem — a busy cache easily
        reaches tens of gigabytes.
      '';
    };

    maxSize = mkOption {
      type = types.str;
      default = "100g";
      description = "Maximum on-disk cache size (rpardini CACHE_MAX_SIZE).";
    };

    registries = mkOption {
      type = types.listOf types.str;
      default = [
        "docker.io"
        "gcr.io"
        "k8s.gcr.io"
        "quay.io"
        "ghcr.io"
      ];
      description = "Upstream registries to intercept and cache.";
    };

    authConfigFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to a credentials file for registries that need auth. Keep it
        out of the Nix store — pass a path managed by your secrets tool
        (agenix/sops/etc.) or an out-of-band file.

        One line per registry, colon-separated:

          REGISTRY:USERNAME:PASSWORD

        Example:

          docker.io:myuser:mypassword
          quay.io:myuser:mytoken
          gcr.io:_json_key:{"type":"service_account",...}

        This friendly form is converted to the proxy's space-separated
        AUTH_REGISTRIES env var at preStart, written only to /run (tmpfs),
        so the expanded value never touches persistent storage.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 3128;
      description = "Host port the proxy container is published on (loopback-fronted by nginx).";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "10.0.0.5";
      description = ''
        Host address the proxy container port is published on. Defaults to
        loopback (127.0.0.1) because nginx fronts the proxy on loopback and
        clients should reach it via the <domain> vhost.

        The nginx vhost follows this: it proxies to the same address, mapping
        a wildcard bind (0.0.0.0 / ::) back to loopback and bracketing IPv6
        literals, so the front end does not go down when you move the publish.

        WARNING: A Docker port publish installs its rule in Docker's own
        iptables chain, which sits IN FRONT OF the NixOS firewall. Binding
        to 0.0.0.0 (or any non-loopback address) therefore exposes the
        rpardini proxy on that interface regardless of networking.firewall.
        The proxy speaks HTTP CONNECT/forward — an off-box, unauthenticated
        binding is an open relay and an SSRF vector into the host's internal
        networks. Only set this to a specific trusted LAN/tailnet address if
        you deliberately need direct :port access, and restrict it yourself.
      '';
    };

    containerHostname = mkOption {
      type = types.str;
      default = "docker-registry-proxy";
      description = "Hostname set inside the proxy container.";
    };

    verifySSL = mkOption {
      type = types.bool;
      default = true;
      description = "Verify TLS certificates of the upstream registries.";
    };

    enableACME = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Let nginx obtain a real ACME/Let's Encrypt certificate for
        <domain>. This is the PUBLIC-facing cert for the front-end and is
        unrelated to the proxy's internal intercept CA. Set false and use
        useACMEHost if a certificate is provisioned elsewhere.
      '';
    };

    useACMEHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Reuse an already-provisioned ACME certificate for this host
        instead of requesting a dedicated one. Mutually exclusive with
        enableACME.
      '';
    };

    extraContainerOptions = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra options passed to the container runtime (e.g. additional --add-host entries).";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.domain != "";
        message = "modules.services.docker-registry-cache: domain must be set";
      }
      {
        assertion = !(cfg.enableACME && cfg.useACMEHost != null);
        message = "modules.services.docker-registry-cache: enableACME and useACMEHost are mutually exclusive";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.cacheDir} 0755 root root -"
      "d ${cfg.cacheDir}/cache 0755 root root -"
      "d ${cfg.cacheDir}/ca 0755 root root -"
    ];

    # rpardini generates its intercept CA into the /ca volume only AFTER
    # first start. This oneshot polls for the container and then the CA
    # file, then copies it where nginx can serve it. mkForce'd ordering +
    # Restart=on-failure handle the cold-first-boot race where the CA does
    # not exist yet when this unit first runs.
    systemd.services.docker-registry-proxy-ca-export = {
      description = "Export the docker-registry-proxy intercept CA for clients";
      unitConfig = {
        After = lib.mkForce [
          "${proxyUnit}.service"
          "docker-registry-proxy.service"
        ];
        Wants = lib.mkForce [
          "${proxyUnit}.service"
          "docker-registry-proxy.service"
        ];
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "5s";
        ExecStart = pkgs.writeShellScript "export-ca" ''
          set -e

          timeout=60
          while [ $timeout -gt 0 ] && ! ${pkgs.docker}/bin/docker ps | grep -q docker-registry-proxy; do
            echo "Waiting for docker-registry-proxy container to start..."
            sleep 1
            timeout=$((timeout - 1))
          done

          timeout=60
          while [ $timeout -gt 0 ] && [ ! -f "${cfg.cacheDir}/ca/ca.crt" ]; do
            echo "Waiting for CA certificate to be generated..."
            sleep 1
            timeout=$((timeout - 1))
          done

          if [ -f "${cfg.cacheDir}/ca/ca.crt" ]; then
            mkdir -p /var/lib/nginx/docker-registry-proxy
            cp "${cfg.cacheDir}/ca/ca.crt" /var/lib/nginx/docker-registry-proxy/ca.crt
            chmod 644 /var/lib/nginx/docker-registry-proxy/ca.crt
            chown nginx:nginx /var/lib/nginx/docker-registry-proxy/ca.crt
            echo "CA certificate exported for client download"
          else
            echo "ERROR: Failed to find CA certificate at ${cfg.cacheDir}/ca/ca.crt"
            exit 1
          fi
        '';
      };
      wantedBy = [ "multi-user.target" ];
    };

    virtualisation.oci-containers = {
      backend = "docker";
      containers.docker-registry-proxy = {
        image = cfg.image;
        hostname = cfg.containerHostname;
        extraOptions = [
          "--add-host=${cfg.containerHostname}:127.0.0.1"
          "--env-file=/run/docker-registry-proxy.env"
        ]
        ++ cfg.extraContainerOptions;
        ports = [
          "${cfg.listenAddress}:${toString cfg.port}:3128"
        ];
        volumes = [
          "${cfg.cacheDir}/cache:/docker_mirror_cache"
          "${cfg.cacheDir}/ca:/ca"
        ]
        ++ optionals (cfg.authConfigFile != null) [
          "${cfg.authConfigFile}:/auth.conf:ro"
        ];
        environment = {
          ENABLE_MANIFEST_CACHE = "true";

          REGISTRIES = concatStringsSep " " cfg.registries;

          CACHE_MAX_SIZE = cfg.maxSize;

          DEBUG = "false";
          DEBUG_NGINX = "false";

          # Do not buffer client requests inside the proxy either.
          PROXY_REQUEST_BUFFERING = "false";

          VERIFY_SSL = if cfg.verifySSL then "true" else "false";
        };
      };
    };

    # Build the AUTH_REGISTRIES env-file just-in-time in tmpfs so the
    # expanded credentials never persist. Always create the env-file (even
    # empty) because the container references it via --env-file.
    systemd.services.${proxyUnit} = {
      preStart = lib.mkBefore (
        if cfg.authConfigFile != null then
          ''
            # Create the env-file 0600 up front: the expanded AUTH_REGISTRIES
            # string holds live registry credentials, and /run is world-
            # readable, so a default-0644 file would leak them to every local
            # user.
            install -m 0600 /dev/null /run/docker-registry-proxy.env
            if [ -f "${cfg.authConfigFile}" ]; then
              AUTH_ENTRIES=$(grep -v '^[[:space:]]*$' "${cfg.authConfigFile}" | tr '\n' ' ' | sed 's/ *$//')
              echo "AUTH_REGISTRIES=$AUTH_ENTRIES" > /run/docker-registry-proxy.env
              echo "Configured AUTH_REGISTRIES from ${cfg.authConfigFile}"
            else
              echo "WARNING: Auth config file ${cfg.authConfigFile} not found"
            fi
          ''
        else
          ''
            install -m 0600 /dev/null /run/docker-registry-proxy.env
          ''
      );
    };

    services.nginx.virtualHosts.${cfg.domain} = {
      forceSSL = cfg.enableACME || cfg.useACMEHost != null;
      enableACME = cfg.enableACME;
      useACMEHost = cfg.useACMEHost;

      # Serve the proxy's intercept CA so clients can trust it:
      #   curl -o proxy.crt https://<domain>/ca.crt
      locations."/ca.crt" = {
        root = "/var/lib/nginx/docker-registry-proxy";
        extraConfig = ''
          add_header Content-Type application/x-x509-ca-cert;
          add_header Content-Disposition 'attachment; filename="docker-registry-proxy-ca.crt"';
        '';
      };

      locations."/" = {
        proxyPass = "http://${proxyUpstream}:${toString cfg.port}";
        extraConfig = ''
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;

          # Image layers are gigabytes. Buffering them would blow the disk
          # and time out — stream everything straight through.
          client_max_body_size 0;
          proxy_request_buffering off;
          proxy_buffering off;

          # Generous timeouts for slow transfers over congested links.
          proxy_read_timeout 900;
          proxy_connect_timeout 60;
          proxy_send_timeout 900;

          proxy_http_version 1.1;
          proxy_set_header Connection "";
        '';
      };
    };
  };
}
