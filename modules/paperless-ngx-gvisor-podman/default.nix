{
  config,
  pkgs,
  lib,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    optionalAttrs
    types
    ;

  cfg = config.services.paperlessGvisor;
in
{
  options.services.paperlessGvisor = {
    enable = mkEnableOption "paperless-ngx as a gVisor-isolated podman container";

    backend = mkOption {
      type = types.enum [
        "podman"
        "docker"
      ];
      default = "podman";
      description = ''
        OCI backend the container runs on. `virtualisation.oci-containers.backend`
        is one setting per host, so a host whose other containers are docker
        picks "docker" here; the gVisor `runsc-host` runtime is registered with
        whichever daemon is chosen and the unit is named `<backend>-paperless`.
      '';
    };

    domain = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "paperless.example.com";
      description = ''
        Public domain the reverse proxy serves paperless on. Must be set when
        enabled. Used verbatim for PAPERLESS_URL and CSRF trusted origins, so it
        must match what users type in the browser.
      '';
    };

    image = mkOption {
      type = types.str;
      default = "ghcr.io/paperless-ngx/paperless-ngx:latest";
      description = ''
        Container image to run. Defaults to the upstream `:latest` tag, which is
        unpinned -- a redeploy silently pulls whatever ghcr currently publishes.
        Pin to a digest or a version tag for reproducible deploys.
      '';
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/paperless";
      description = ''
        Host directory holding paperless state (data/media/consume/export). It
        and its subdirs are created by tmpfiles, owned by uid/gid, and bind
        mounted into the container so state survives image churn.
      '';
    };

    uid = mkOption {
      type = types.int;
      default = 3500;
      description = ''
        Numeric uid the container runs paperless as (via the image's
        USERMAP_UID). The bind-mount dirs are chowned to this id so paperless can
        write them. The specific number is arbitrary -- pick one that does not
        collide with other users on the host.
      '';
    };

    gid = mkOption {
      type = types.int;
      default = 3500;
      description = "Numeric gid paired with `uid` (via the image's USERMAP_GID).";
    };

    port = mkOption {
      type = types.port;
      default = 3500;
      description = ''
        Port paperless listens on. Because the container is `--network=host`,
        this is a real host port -- it must be free on the host and must match the
        reverse-proxy upstream.
      '';
    };

    redisPort = mkOption {
      type = types.port;
      default = 6379;
      description = "Loopback port for the paperless-dedicated Redis instance.";
    };

    bindAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = ''
        Address paperless binds to (PAPERLESS_BIND_ADDR). Because the container
        is `--network=host`, this is a real host bind. It defaults to loopback so
        the app is reachable only through the TLS reverse proxy, never in
        cleartext on other interfaces. Only widen this (e.g. `0.0.0.0`) if you
        deliberately want the plaintext app port exposed and keep it firewalled.
      '';
    };

    acmeHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "example.com";
      description = ''
        Name of the ACME certificate to reuse for the nginx vhost
        (services.nginx.virtualHosts.<domain>.useACMEHost). Leave null to let
        nginx obtain its own cert for `domain` via the enableACME path you
        configure elsewhere.
      '';
    };

    filenameFormat = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "{correspondent}/{created_year}/{created_year}.{created_month}.{created_day}-{title}";
      description = ''
        Value for PAPERLESS_FILENAME_FORMAT (how paperless lays out stored
        originals). Null leaves the image default.
      '';
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Extra environment variables merged into the container.";
    };

    manageNginx = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether this module configures the nginx virtualHost for `domain`. Set
        false to wire your own reverse proxy to http://127.0.0.1:<port>/.
      '';
    };

    manageRedis = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether this module runs a dedicated loopback Redis for paperless. Set
        false and point extraEnvironment.PAPERLESS_REDIS at your own instance.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.domain != null;
          message = "services.paperlessGvisor: domain must be set when enabled.";
        }
      ];
    }

    (mkIf (cfg.backend == "podman") {
      virtualisation.podman = {
        enable = true;
        extraPackages = [ pkgs.gvisor ];
      };

      virtualisation.containers.containersConf.settings.engine.runtimes.runsc-host = [
        "${pkgs.writeShellScript "runsc-host" ''exec ${pkgs.gvisor}/bin/runsc --network=host "$@"''}"
      ];
    })

    (mkIf (cfg.backend == "docker") {
      virtualisation.docker.daemon.settings.runtimes.runsc-host = {
        path = "${pkgs.writeShellScript "runsc-host" ''exec ${pkgs.gvisor}/bin/runsc --network=host "$@"''}";
      };
    })

    (mkIf cfg.manageNginx {
      services.nginx.virtualHosts.${cfg.domain} = {
        forceSSL = true;
        enableACME = cfg.acmeHost == null;
        useACMEHost = cfg.acmeHost;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}/";
          proxyWebsockets = true;
          recommendedProxySettings = true;
        };
      };
    })

    (mkIf cfg.manageRedis {
      services.redis.servers.paperless = {
        enable = true;
        port = cfg.redisPort;
        bind = "127.0.0.1";
      };

      systemd.services."${cfg.backend}-paperless" = {
        after = [ "redis-paperless.service" ];
        requires = [ "redis-paperless.service" ];
      };
    })

    {
      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0700 ${toString cfg.uid} ${toString cfg.gid} - -"
        "d ${cfg.dataDir}/data 0700 ${toString cfg.uid} ${toString cfg.gid} - -"
        "d ${cfg.dataDir}/media 0700 ${toString cfg.uid} ${toString cfg.gid} - -"
        "d ${cfg.dataDir}/consume 0700 ${toString cfg.uid} ${toString cfg.gid} - -"
        "d ${cfg.dataDir}/export 0700 ${toString cfg.uid} ${toString cfg.gid} - -"
      ];

      virtualisation.oci-containers.backend = cfg.backend;
      virtualisation.oci-containers.containers.paperless = {
        inherit (cfg) image;

        environment = {
          PAPERLESS_REDIS = "redis://127.0.0.1:${toString cfg.redisPort}";
          PAPERLESS_URL = "https://${cfg.domain}";
          PAPERLESS_CSRF_TRUSTED_ORIGINS = "https://${cfg.domain}";
          PAPERLESS_PORT = toString cfg.port;
          PAPERLESS_BIND_ADDR = cfg.bindAddress;
          PAPERLESS_DATA_DIR = "/usr/src/paperless/data";
          PAPERLESS_MEDIA_ROOT = "/usr/src/paperless/media";
          PAPERLESS_CONSUMPTION_DIR = "/usr/src/paperless/consume";
          USERMAP_UID = toString cfg.uid;
          USERMAP_GID = toString cfg.gid;
        }
        // optionalAttrs (cfg.filenameFormat != null) {
          PAPERLESS_FILENAME_FORMAT = cfg.filenameFormat;
        }
        // cfg.extraEnvironment;

        extraOptions = [
          "--runtime=runsc-host"
          "--network=host"
        ];

        volumes = [
          "${cfg.dataDir}/data:/usr/src/paperless/data"
          "${cfg.dataDir}/media:/usr/src/paperless/media"
          "${cfg.dataDir}/consume:/usr/src/paperless/consume"
          "${cfg.dataDir}/export:/usr/src/paperless/export"
        ];
      };
    }
  ]);
}
