# openwebui-litellm-multideploy
#
# One option set that fronts Open WebUI (over an OpenAI-compatible backend such
# as LiteLLM) behind nginx TLS, in one of three interchangeable ways:
#
#   deploymentMethod = "docker"          OCI container via virtualisation.oci-containers
#                    | "nixos-container" declarative NixOS container, private network
#                    | "systemd"         native systemd service (needs pkgs.open-webui)
#
# The host-side user/group, data directory layout, and nginx vhost are shared
# across all three; only the runtime wrapper differs.
#
# Traps this module bakes in (see README):
#   - the nginx "/" location deliberately does NOT re-set the Host header
#   - under docker / nixos-container the vector store + static dir live INSIDE
#     the container and are lost on recreate unless you add mounts
#   - ~10 of the typed feature toggles are decorative; real features go through
#     extraEnvironment
#
# Import it and set config.services.openwebuiMulti.* .
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.openwebuiMulti;

  openwebuiPackage = cfg.package;

  commonEnvironment = {
    PORT = toString cfg.port;
    WEBUI_URL = "https://${cfg.domain}";

    OPENAI_API_BASE_URL = cfg.backendHost;
    OPENAI_API_KEY = if cfg.backendApiKey != null then cfg.backendApiKey else "dummy-key-for-local";

    CORS_ALLOW_ORIGIN = "https://${cfg.domain}";

    ANONYMIZED_TELEMETRY = "false";
    CHROMA_ANONYMIZED_TELEMETRY = "false";
    STATIC_DIR = "${cfg.dataDir}/static";

    CHROMA_DATA_PATH = "${cfg.dataDir}/vector_db";
    CHROMA_PERSIST_DIRECTORY = "${cfg.dataDir}/vector_db";

    # Security-relevant account policy: wired so the typed toggles actually take
    # effect. Defaults match Open WebUI's own defaults, so this changes nothing
    # unless you set the options. extraEnvironment still merges last and wins.
    ENABLE_SIGNUP = boolToString cfg.enableSignup;
    DEFAULT_USER_ROLE = cfg.defaultUserRole;
  }
  // (optionalAttrs (cfg.observability.enable && cfg.observability.otlpEndpoint != null) {
    OTEL_EXPORTER_OTLP_ENDPOINT = cfg.observability.otlpEndpoint;
  })
  // cfg.extraEnvironment;

  sharedServiceConfig = {
    Type = "simple";
    ExecStart = "${openwebuiPackage}/bin/open-webui serve --host 0.0.0.0 --port ${toString cfg.port}";
    Restart = "always";
    RestartSec = "10s";

    User = "openwebui";
    Group = "openwebui";

    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    RestrictNamespaces = true;
    LockPersonality = true;
    RestrictRealtime = true;
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
      "@resources"
    ];
    UMask = "0022";
  };
in
{
  options.services.openwebuiMulti = {
    enable = mkEnableOption "Open WebUI service (docker / nixos-container / systemd)";

    deploymentMethod = mkOption {
      type = types.enum [
        "docker"
        "nixos-container"
        "systemd"
      ];
      default = "docker";
      description = ''
        Deployment method for Open WebUI:
        - docker: Run as an OCI container (default)
        - nixos-container: Run in a declarative NixOS container
        - systemd: Run as a native systemd service (requires the open-webui package)
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.open-webui or (throw "services.openwebuiMulti.package: pkgs.open-webui not available; set services.openwebuiMulti.package explicitly");
      defaultText = literalExpression "pkgs.open-webui";
      description = ''
        Open WebUI package, used by the systemd and nixos-container deployment
        methods (the docker method uses the OCI image instead). Only evaluated
        when one of those methods is selected.
      '';
    };

    domain = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "chat.example.com";
      description = "Public domain name for the nginx vhost (required).";
    };

    acmeHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "example.com";
      description = ''
        ACME certificate host for the nginx vhost (useACMEHost). Required in
        practice: nginx fails to evaluate useACMEHost when this is null.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 8080;
      description = "Port Open WebUI listens on (and nginx proxies to).";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/openwebui";
      description = "Host directory holding Open WebUI state (data/cache/static/vector_db).";
    };

    uid = mkOption {
      type = types.int;
      default = 3200;
      description = "UID for the openwebui service user.";
    };

    gid = mkOption {
      type = types.int;
      default = 3200;
      description = "GID for the openwebui service group.";
    };

    # --- docker ---------------------------------------------------------------

    containerBackend = mkOption {
      type = types.enum [
        "docker"
        "podman"
      ];
      default = "docker";
      description = "OCI backend used when deploymentMethod is 'docker'.";
    };

    image = mkOption {
      type = types.str;
      default = "ghcr.io/open-webui/open-webui:v0.10.2@sha256:9fcea9c6e32ab60b0498f3986c6cdf651ddbe61db48d2213a3d28048ddd673d4";
      description = ''
        OCI image reference used when deploymentMethod is 'docker'. The default
        is pinned to a released version by digest so a redeploy can never
        silently pull different code (a mutable tag like `:main` or `:latest`
        would). When you bump the version, update the digest with it — or point
        at a locally built image loaded via imageFile.
      '';
    };

    imageFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Optional image tarball (e.g. from dockerTools.pullImage /
        buildLayeredImage) loaded before starting the container. When null the
        backend pulls `image` from its registry.
      '';
    };

    # --- nixos-container ------------------------------------------------------

    containerNetwork = mkOption {
      type = types.submodule {
        options = {
          hostAddress = mkOption {
            type = types.str;
            default = "192.168.201.1";
            description = "Host side of the private container link (nixos-container).";
          };
          localAddress = mkOption {
            type = types.str;
            default = "192.168.201.2";
            description = "Container side of the private container link (nixos-container).";
          };
        };
      };
      default = { };
      description = "Private-network addresses for the nixos-container deployment.";
    };

    containerNameservers = mkOption {
      type = types.listOf types.str;
      default = [
        "1.1.1.1"
        "8.8.8.8"
      ];
      description = "Resolvers configured inside the nixos-container.";
    };

    # --- backend (OpenAI-compatible, e.g. LiteLLM) ----------------------------

    backendHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "http://127.0.0.1:4000/v1";
      description = ''
        OpenAI-compatible backend base URL (OPENAI_API_BASE_URL). Include the
        `/v1` suffix. Point this at your LiteLLM / gateway endpoint.
      '';
    };

    backendApiKey = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        API key for the backend (OPENAI_API_KEY). When null, a literal
        placeholder is sent so a keyless local gateway still authenticates.
        Do not hardcode a real secret here in a public config; inject it via
        extraEnvironment with an *_FILE variable or an EnvironmentFile instead.
      '';
    };

    # --- decorative typed toggles (declared, NOT wired — see README) ----------
    # Kept for API compatibility / documentation. Setting them does nothing;
    # drive the real features through extraEnvironment.

    embeddingEngine = mkOption {
      type = types.enum [
        "openai"
        "ollama"
        "sentence-transformers"
      ];
      default = "openai";
      description = "Decorative. Not wired into config; use extraEnvironment.";
    };

    embeddingModel = mkOption {
      type = types.str;
      default = "text-embedding-3-small";
      description = "Decorative. Not wired into config; use extraEnvironment.";
    };

    enableSignup = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether self-service account signup is allowed (ENABLE_SIGNUP). Set to
        false to close registration. Wired into the runtime env; extraEnvironment
        (ENABLE_SIGNUP) still overrides it.
      '';
    };

    defaultUserRole = mkOption {
      type = types.enum [
        "admin"
        "user"
        "pending"
      ];
      default = "pending";
      description = ''
        Role assigned to newly registered users (DEFAULT_USER_ROLE). "pending"
        requires admin approval before access. Wired into the runtime env;
        extraEnvironment (DEFAULT_USER_ROLE) still overrides it.
      '';
    };

    enableWebSearch = mkOption {
      type = types.bool;
      default = false;
      description = "Decorative. Not wired into config; use extraEnvironment.";
    };

    webSearchEngine = mkOption {
      type = types.str;
      default = "searxng";
      description = "Decorative. Not wired into config; use extraEnvironment.";
    };

    enableImageGeneration = mkOption {
      type = types.bool;
      default = false;
      description = "Decorative. Not wired into config; use extraEnvironment.";
    };

    enableAudioTranscription = mkOption {
      type = types.bool;
      default = false;
      description = "Decorative. Not wired into config; use extraEnvironment.";
    };

    observability = {
      enable = mkEnableOption "OpenTelemetry export (only otlpEndpoint is actually wired)";

      otlpEndpoint = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "http://localhost:4318";
        description = "OTLP collector endpoint (OTEL_EXPORTER_OTLP_ENDPOINT). The one wired observability field.";
      };

      serviceName = mkOption {
        type = types.str;
        default = "openwebui";
        description = "Decorative. Not wired into config.";
      };

      enableMetrics = mkOption {
        type = types.bool;
        default = false;
        description = "Decorative. Not wired into config.";
      };
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        Extra environment variables, merged LAST into the container/service env
        so they also override defaults. This is the real escape hatch: web
        search, image generation, OAuth, Ollama, speech-to-text, signup policy,
        etc. are all configured here via Open WebUI's own env vars.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.domain != null;
          message = "services.openwebuiMulti: domain must be set";
        }
        {
          assertion = cfg.deploymentMethod == "systemd" -> (cfg.package != null);
          message = "services.openwebuiMulti: systemd deployment requires the open-webui package";
        }
      ];

      users.users.openwebui = {
        uid = cfg.uid;
        isSystemUser = true;
        group = "openwebui";
        description = "Open WebUI service user";
      };

      users.groups.openwebui.gid = cfg.gid;

      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0700 ${toString cfg.uid} ${toString cfg.gid}"
        "d ${cfg.dataDir}/data 0700 ${toString cfg.uid} ${toString cfg.gid}"
        "d ${cfg.dataDir}/cache 0700 ${toString cfg.uid} ${toString cfg.gid}"
        "d ${cfg.dataDir}/static 0700 ${toString cfg.uid} ${toString cfg.gid}"
        "d ${cfg.dataDir}/vector_db 0700 ${toString cfg.uid} ${toString cfg.gid}"
      ];

      services.nginx.virtualHosts.${cfg.domain} = {
        forceSSL = true;
        useACMEHost = cfg.acmeHost;
        locations."/" = {
          proxyPass = "http://${
            if cfg.deploymentMethod == "nixos-container" then cfg.containerNetwork.localAddress else "127.0.0.1"
          }:${toString cfg.port}";
          proxyWebsockets = true;
          # NOTE: do NOT add `proxy_set_header Host ...` here.
          # recommendedProxySettings already forwards Host; a second Host header
          # is a duplicate that uvicorn rejects with 400 "Invalid HTTP request".
          extraConfig = ''
            proxy_connect_timeout 600;
            proxy_send_timeout 600;
            proxy_read_timeout 600;
            send_timeout 600;

            proxy_buffering off;
            proxy_buffer_size 128k;
            proxy_buffers 4 256k;
            proxy_busy_buffers_size 256k;

            client_max_body_size 100M;
          '';
        };
      };
    }

    (mkIf (cfg.deploymentMethod == "docker") {
      virtualisation.oci-containers = {
        backend = lib.mkDefault cfg.containerBackend;
        containers.openwebui = {
          inherit (cfg) image imageFile;
          environment = commonEnvironment;
          # WARNING: only data/ and cache/ are mounted. CHROMA_DATA_PATH and
          # STATIC_DIR still point at unmounted host paths, so the vector store
          # and static assets land inside the container and are lost on
          # recreate. Add volumes for them if you rely on RAG persistence.
          volumes = [
            "${cfg.dataDir}/data:/app/backend/data"
            "${cfg.dataDir}/cache:/app/backend/cache"
          ];
          ports = [
            "127.0.0.1:${toString cfg.port}:${toString cfg.port}"
          ];
          extraOptions = [
            # lets the container reach a host-local backend (LiteLLM) as
            # host.docker.internal
            "--add-host=host.docker.internal:host-gateway"
          ];
        };
      };

      networking.firewall.interfaces.docker0.allowedTCPPorts = [ cfg.port ];
    })

    (mkIf (cfg.deploymentMethod == "nixos-container") {
      containers.openwebui = {
        autoStart = true;
        privateNetwork = true;
        hostAddress = cfg.containerNetwork.hostAddress;
        localAddress = cfg.containerNetwork.localAddress;

        config =
          {
            config,
            pkgs,
            ...
          }:
          {
            system.stateVersion = "24.11";

            networking.firewall.allowedTCPPorts = [ cfg.port ];
            networking.nameservers = cfg.containerNameservers;

            environment.systemPackages = [ pkgs.ffmpeg ];

            systemd.services.openwebui = {
              description = "Open WebUI";
              after = [ "network.target" ];
              wantedBy = [ "multi-user.target" ];

              environment = commonEnvironment // {
                DATA_DIR = "/data";
                CACHE_DIR = "/cache";
              };

              preStart = ''
                mkdir -p /data /cache /static /vector_db
                chown -R openwebui:openwebui /data /cache /static /vector_db
                chmod -R 755 /data /cache /static /vector_db
              '';

              path = with pkgs; [
                ffmpeg
                coreutils
              ];

              serviceConfig = sharedServiceConfig // {
                # Same trap as docker: only /data and /cache are bind-mounted
                # back to the host; /static and /vector_db stay in the container.
                ReadWritePaths = [
                  "/data"
                  "/cache"
                ];
              };
            };

            users.users.openwebui = {
              uid = cfg.uid;
              isSystemUser = true;
              group = "openwebui";
            };
            users.groups.openwebui.gid = cfg.gid;
          };

        bindMounts = {
          "/data" = {
            hostPath = "${cfg.dataDir}/data";
            isReadOnly = false;
          };
          "/cache" = {
            hostPath = "${cfg.dataDir}/cache";
            isReadOnly = false;
          };
        };
      };
    })

    (mkIf (cfg.deploymentMethod == "systemd") {
      systemd.services.openwebui = {
        description = "Open WebUI";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];

        environment = commonEnvironment // {
          DATA_DIR = "${cfg.dataDir}/data";
          CACHE_DIR = "${cfg.dataDir}/cache";
        };

        path = with pkgs; [
          ffmpeg
          coreutils
        ];

        # Only the systemd method persists EVERYTHING: the whole tree is
        # writable, so the vector store and static dir survive.
        serviceConfig = sharedServiceConfig // {
          WorkingDirectory = cfg.dataDir;
          ReadWritePaths = [
            cfg.dataDir
            "${cfg.dataDir}/data"
            "${cfg.dataDir}/cache"
            "${cfg.dataDir}/static"
            "${cfg.dataDir}/vector_db"
            "${cfg.dataDir}/vector_db/chroma.sqlite3"
          ];
          PrivateDevices = true;
        };
      };
    })
  ]);
}
