# Self-host Firecrawl on NixOS from OCI images.
#
# Firecrawl (https://github.com/firecrawl/firecrawl) scrapes/crawls websites
# into clean Markdown. Upstream ships the app as prebuilt OCI images. This
# module wires the api + worker + a headless-Chromium (playwright) container
# together with a dedicated Redis and, optionally, an existing Postgres for the
# newer "NuQ" job queue.
#
# Two ways to supply the images:
#   1. Registry pull  -- set `images.api` / `images.playwright` to references a
#      local Docker/Podman can pull, and leave the *ImageFile options null.
#   2. Offline tarball -- set `images.apiImageFile` / `images.playwrightImageFile`
#      to `docker save`-style tarballs (or `pkgs.dockerTools.buildImage`
#      outputs). The oci-containers backend then `docker load`s them at start,
#      so deploys never touch a registry and stay reproducible. When using a
#      tarball, `images.api` / `images.playwright` must still be set to the
#      exact image tag *inside* the tarball.
#
# Enable `initSchema` to install the NuQ Postgres queue schema on the same host.
# See README.md for the reasoning behind the ordering traps.

{
  config,
  lib,
  ...
}:
with lib;
let
  cfg = config.modules.services.firecrawl;
  apiPort = 3002;
  playwrightPort = 3000;
in
{
  options.modules.services.firecrawl = {
    enable = mkEnableOption "firecrawl service";

    domain = mkOption {
      description = "Public domain to serve the API on via nginx. null disables the vhost.";
      type = types.nullOr types.str;
      default = null;
      example = "firecrawl.example.com";
    };

    acmeHost = mkOption {
      description = ''
        Name of a security.acme.certs entry to use for TLS (useACMEHost).
        Required when domain is set.
      '';
      type = types.nullOr types.str;
      default = null;
      example = "example.com";
    };

    listenAddress = mkOption {
      description = ''
        Host address the api container's port is published on. Defaults to
        127.0.0.1 (loopback) so the API is reachable only from the host itself
        and via the nginx vhost, never directly from the LAN/internet.

        Firecrawl's core function is to fetch arbitrary caller-supplied URLs, so
        an unauthenticated instance is a full SSRF primitive. Only change this to
        0.0.0.0 (all interfaces) if you have set useDbAuthentication = true AND
        deliberately want the plaintext API exposed off-box.
      '';
      type = types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
    };

    openFirewall = mkOption {
      description = ''
        Open the plaintext API port (3002) in the host firewall. Defaults to
        false: reach the API through the nginx+TLS vhost instead. Opening this
        port exposes the raw Firecrawl API to every interface the firewall
        governs; combined with useDbAuthentication = false that is an
        unauthenticated arbitrary-URL fetcher (SSRF) open to the network. Only
        enable on a trusted network and preferably with authentication on.
      '';
      type = types.bool;
      default = false;
    };

    dataDir = mkOption {
      description = "Directory to store Firecrawl data.";
      type = types.str;
      default = "/var/lib/firecrawl";
    };

    user = mkOption {
      description = "System user that owns dataDir and runs Redis alongside.";
      type = types.str;
      default = "firecrawl";
    };

    group = mkOption {
      description = "Primary group for the Firecrawl user.";
      type = types.str;
      default = "firecrawl";
    };

    uid = mkOption {
      description = "Optional fixed UID for the Firecrawl user. null lets NixOS allocate one.";
      type = types.nullOr types.int;
      default = null;
    };

    gid = mkOption {
      description = "Optional fixed GID for the Firecrawl group. null lets NixOS allocate one.";
      type = types.nullOr types.int;
      default = null;
    };

    images = {
      api = mkOption {
        description = ''
          Image reference for the api + worker container (they share an image).
          When apiImageFile is set, this must match the tag inside that tarball.
        '';
        type = types.str;
        default = "firecrawl/firecrawl:latest";
      };
      playwright = mkOption {
        description = "Image reference for the headless-Chromium playwright container.";
        type = types.str;
        default = "firecrawl/playwright-service:latest";
      };
      apiImageFile = mkOption {
        description = "Optional image tarball to `docker load` for the api/worker image (offline deploys).";
        type = types.nullOr types.path;
        default = null;
      };
      playwrightImageFile = mkOption {
        description = "Optional image tarball to `docker load` for the playwright image (offline deploys).";
        type = types.nullOr types.path;
        default = null;
      };
    };

    redisBind = mkOption {
      description = ''
        Address list for the Redis bind directive. The default restricts the
        listener to loopback plus the default docker bridge gateway
        (172.17.0.1) instead of all interfaces; the leading "-" tells Redis to
        skip the bridge address if it does not exist yet at start. Redis has
        no requirePass here, so this list is the only thing keeping other
        networks away from it -- keep it to loopback plus the exact gateway
        the containers dial in redisUrl (adjust both together for a custom
        bridge subnet or Podman). See README before widening.
      '';
      type = types.str;
      default = "127.0.0.1 -172.17.0.1";
    };

    redisUrl = mkOption {
      description = ''
        Redis URL the containers connect to. Because the containers reach the
        host over the OCI bridge, this must resolve to the bridge gateway from
        inside a container -- with the default docker bridge that is
        172.17.0.1. Adjust for a custom bridge subnet or Podman.
      '';
      type = types.str;
      default = "redis://172.17.0.1:6379";
    };

    numWorkersPerQueue = mkOption {
      description = "Number of workers per queue (NUM_WORKERS_PER_QUEUE).";
      type = types.int;
      default = 8;
    };

    useDbAuthentication = mkOption {
      description = ''
        USE_DB_AUTHENTICATION. false lets Firecrawl accept keyless requests --
        only appropriate on a trusted/intranet deployment.
      '';
      type = types.bool;
      default = false;
    };

    initSchema = mkOption {
      description = ''
        Install the Firecrawl "NuQ" Postgres queue schema into a local Postgres
        instance via a systemd one-shot, ordered before the api and worker
        containers start. Requires services.postgresql enabled on the same host
        with pg_cron loaded (shared_preload_libraries = [ "pg_cron" ]) and
        cron.database_name = databaseName.

        The one-shot runs firecrawl-nuq.sql (shipped alongside this module) as
        the postgres superuser and grants schema access to databaseUser.
      '';
      type = types.bool;
      default = false;
    };

    databaseName = mkOption {
      description = "Postgres database that holds the NuQ schema.";
      type = types.str;
      default = "firecrawl";
    };

    databaseUser = mkOption {
      description = ''
        Postgres role the Firecrawl containers connect as. The init grants this
        role USAGE + ALL on the nuq schema. Create it via
        services.postgresql.ensureUsers.
      '';
      type = types.str;
      default = "firecrawl";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.domain != null -> cfg.acmeHost != null;
        message = "modules.services.firecrawl: acmeHost must be set when domain is configured";
      }
      {
        assertion = cfg.initSchema -> config.services.postgresql.enable;
        message = "modules.services.firecrawl.initSchema requires services.postgresql to be enabled on the same host";
      }
    ];

    users = {
      users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.dataDir;
        createHome = true;
        extraGroups = [ "redis" ];
      }
      // optionalAttrs (cfg.uid != null) { inherit (cfg) uid; };
      groups.${cfg.group} = optionalAttrs (cfg.gid != null) { inherit (cfg) gid; };
      groups.redis = { };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/data 0700 ${cfg.user} ${cfg.group} -"
    ];

    # Pin the public name to loopback so the API resolves its own name for
    # self-referential URLs (e.g. webhook callbacks) and loops back through nginx.
    networking.hosts = mkIf (cfg.domain != null) {
      "127.0.0.1" = [ cfg.domain ];
    };

    # Listener limited to loopback + bridge gateway (cfg.redisBind), no wider.
    # The 2 GB cap + allkeys-lru lets the queue/rate-limit store shed oldest
    # keys under pressure instead of erroring.
    services.redis.servers."firecrawl" = {
      enable = true;
      bind = cfg.redisBind;
      port = 6379;
      settings = {
        "maxmemory" = "2gb";
        "maxmemory-policy" = "allkeys-lru";
      };
    };

    services.nginx = mkIf (cfg.domain != null) {
      virtualHosts.${cfg.domain} = {
        forceSSL = true;
        useACMEHost = cfg.acmeHost;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString apiPort}";
          proxyWebsockets = true;
        };
      };
    };

    virtualisation.oci-containers = {
      backend = lib.mkDefault "docker";
      containers = {
        firecrawl-playwright = {
          image = cfg.images.playwright;
          imageFile = cfg.images.playwrightImageFile;
          hostname = "playwright-service";
          environment = {
            PORT = toString playwrightPort;
            BLOCK_MEDIA = "true";
          };
          # Published on loopback only; inter-container traffic uses the OCI
          # network DNS name (playwright-service), not this host-published port.
          ports = [ "${cfg.listenAddress}:${toString playwrightPort}:${toString playwrightPort}" ];
        };

        firecrawl-api = {
          image = cfg.images.api;
          imageFile = cfg.images.apiImageFile;
          hostname = "api";
          dependsOn = [ "firecrawl-playwright" ];
          environment = {
            REDIS_URL = cfg.redisUrl;
            REDIS_RATE_LIMIT_URL = cfg.redisUrl;
            PLAYWRIGHT_MICROSERVICE_URL = "http://playwright-service:${toString playwrightPort}";
            USE_DB_AUTHENTICATION = lib.boolToString cfg.useDbAuthentication;
            PORT = toString apiPort;
            NUM_WORKERS_PER_QUEUE = toString cfg.numWorkersPerQueue;
            HOST = "0.0.0.0";
          };
          ports = [ "${cfg.listenAddress}:${toString apiPort}:${toString apiPort}" ];
          volumes = [
            "${cfg.dataDir}/data:/app/data"
          ];
          cmd = [
            "node"
            "dist/src/index.js"
          ];
        };

        # Same image as api; FLY_PROCESS_GROUP=worker is what makes the upstream
        # image branch into worker behaviour.
        firecrawl-worker = {
          image = cfg.images.api;
          imageFile = cfg.images.apiImageFile;
          hostname = "worker";
          dependsOn = [ "firecrawl-api" ];
          environment = {
            REDIS_URL = cfg.redisUrl;
            REDIS_RATE_LIMIT_URL = cfg.redisUrl;
            PLAYWRIGHT_MICROSERVICE_URL = "http://playwright-service:${toString playwrightPort}";
            USE_DB_AUTHENTICATION = lib.boolToString cfg.useDbAuthentication;
            PORT = toString apiPort;
            NUM_WORKERS_PER_QUEUE = toString cfg.numWorkersPerQueue;
            HOST = "0.0.0.0";
            FLY_PROCESS_GROUP = "worker";
          };
          volumes = [
            "${cfg.dataDir}/data:/app/data"
          ];
          cmd = [
            "node"
            "dist/src/services/queue-worker.js"
          ];
        };
      };
    };

    # Opt-in only. By default the API is reachable via the nginx vhost (or
    # loopback), never opened to the network, because an unauthenticated
    # Firecrawl instance is an arbitrary-URL fetcher (SSRF).
    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ apiPort ];

    systemd.services =
      let
        backend = config.virtualisation.oci-containers.backend;
        apiUnit = "${backend}-firecrawl-api.service";
        workerUnit = "${backend}-firecrawl-worker.service";
      in
      mkMerge [
        # The docker bridge (and its 172.17.0.1 gateway) only exists once the
        # daemon is up; without this ordering Redis skips the "-" bind address
        # and containers cannot reach it until a Redis restart.
        (mkIf (backend == "docker") {
          redis-firecrawl = {
            after = [ "docker.service" ];
            wants = [ "docker.service" ];
          };
        })
        (mkIf cfg.initSchema {
          # Ordering trap: order on postgresql.TARGET, not postgresql.service.
          # The target gates on postgresql-setup.service, which runs
          # ensureDatabases; plain postgresql.service goes active *before* the
          # database exists and would race this psql run. The api/worker units
          # then require+order-after this one-shot so they never start on an
          # empty schema. The SQL is idempotent, so this re-runs safely on boot.
          firecrawl-nuq-init = {
            description = "Install Firecrawl NuQ schema into ${cfg.databaseName}";
            wantedBy = [ "multi-user.target" ];
            after = [ "postgresql.target" ];
            requires = [ "postgresql.target" ];
            before = [
              apiUnit
              workerUnit
            ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = "postgres";
              ExecStart = "${config.services.postgresql.package}/bin/psql -v ON_ERROR_STOP=1 -v dbrole=${cfg.databaseUser} -d ${cfg.databaseName} -f ${./firecrawl-nuq.sql}";
            };
          };
          "${backend}-firecrawl-api" = {
            after = [ "firecrawl-nuq-init.service" ];
            requires = [ "firecrawl-nuq-init.service" ];
          };
          "${backend}-firecrawl-worker" = {
            after = [ "firecrawl-nuq-init.service" ];
            requires = [ "firecrawl-nuq-init.service" ];
          };
        })
      ];
  };
}
