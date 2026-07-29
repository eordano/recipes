# forgejo-git-server — self-hosting Forgejo 15.x behind nginx on NixOS.
#
# Supports two deployment shapes behind one option set:
#   - asContainer = true  : a rootless podman container built from a
#                           locally-assembled OCI image (optionally on a
#                           sandboxed runtime like gVisor/runsc).
#   - asContainer = false : NixOS's native services.forgejo, typically over
#                           a unix socket.
#
# Both shapes share the same nginx TLS front-end, database wiring and optional
# OIDC. Most of the file's bulk is workarounds for Forgejo 15.x's stricter
# startup checks — read the inline comments before touching RUN_USER, the
# authorized_keys handling, the app.ini password templating, or proxy_buffering.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.modules.forgejo;
  forgejoDbCfg = removeAttrs cfg.database [
    "password"
    "configureLocalAuth"
    "sslMode"
  ];

  containerUid = toString (if cfg.uid != null then cfg.uid else 1000);
  containerGid = toString (if cfg.gid != null then cfg.gid else 1000);

  # Synthetic /etc/passwd for the container. This is load-bearing: it names the
  # container uid "root" so that Forgejo's run-user check resolves the running
  # user to the name we hardcode as RUN_USER below. See the RUN_USER comment.
  containerEtc = pkgs.runCommand "forgejo-etc" { } ''
    mkdir -p $out/etc $out/usr/bin
    echo 'root:x:${containerUid}:${containerGid}:root:/data:/bin/bash' > $out/etc/passwd
    echo 'root:x:${containerGid}:' > $out/etc/group
    ln -s ${pkgs.coreutils}/bin/env $out/usr/bin/env
  '';

  forgejoImage = pkgs.dockerTools.buildLayeredImage {
    name = "forgejo";
    tag = "latest";
    contents = with pkgs; [
      forgejo
      git
      git-lfs
      bash
      coreutils
      gnugrep
      cacert
      containerEtc
    ];
    config = {
      Cmd = [
        "${pkgs.forgejo}/bin/forgejo"
        "--config"
        "/data/custom/conf/app.ini"
      ];
      WorkingDir = "/data";
      Env = [
        "HOME=/data"
        "FORGEJO_WORK_DIR=/data"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ];
    };
  };

  # The DB password never enters the Nix store: app.ini ships with a literal
  # `FORGEJO_DB_PASSWD` placeholder that preStart sed-substitutes from the
  # runtime passwordFile at deploy time (see podman-forgejo.preStart below).
  appIni = pkgs.writeText "forgejo-app.ini" ''
    APP_NAME = ${cfg.appName}
    # Stays "root": containerEtc names the container uid (cfg.uid) "root" in
    # /etc/passwd, so Forgejo's run-user check (mustCurrentRunUserMatch)
    # resolves the running user to "root". Forgejo 15.x makes that check fatal —
    # RUN_USER must equal the name the in-container passwd gives cfg.uid, which
    # is "root" here. Change one without the other and startup hard-fails.
    RUN_USER = root
    RUN_MODE = prod
    WORK_PATH = /data

    [database]
    DB_TYPE = ${cfg.database.type}
    HOST = ${cfg.database.host}:${toString cfg.database.port}
    NAME = ${cfg.database.name}
    USER = ${cfg.database.user}
    PASSWD = `FORGEJO_DB_PASSWD`
    SSL_MODE = ${cfg.database.sslMode}
    MAX_OPEN_CONNS = 50
    MAX_IDLE_CONNS = 10
    CONN_MAX_LIFETIME = 5m

    [security]
    INSTALL_LOCK = true

    [server]
    # Forgejo 15.x hard-fails at startup if /data/.ssh/authorized_keys contains
    # any key not present in the DB (modules/ssh/init.go). If you have keys that
    # were added out-of-band (e.g. a CI runner or a mirror daemon pulling over
    # git-over-ssh), the new check flags them as "unexpected" and aborts. The
    # upstream "just delete the file" fix would drop those keys and can lock out
    # legitimate fetchers. Permitting them keeps the keys authenticating
    # normally; this only disables the startup consistency assertion.
    SSH_ALLOW_UNEXPECTED_AUTHORIZED_KEYS = true
    LFS_START_SERVER = true
    PROTOCOL = http
    # Bind the plaintext listener to loopback only. With the default
    # --network=host the container shares the host netns, so nginx reaches it
    # at 127.0.0.1:${toString cfg.httpPort} and nothing off-box should ever
    # touch this unauthenticated, TLS-less port. If you switch to an isolated
    # container network you must set this to 0.0.0.0 (and repoint the nginx
    # proxyPass) — see containerExtraOptions.
    HTTP_ADDR = 127.0.0.1
    HTTP_PORT = ${toString cfg.httpPort}
    DOMAIN = ${cfg.domain}
    ROOT_URL = https://${cfg.domain}
    LOCAL_ROOT_URL = http://127.0.0.1:${toString cfg.httpPort}/
    ${lib.optionalString (cfg.sshPort != null) ''
      DISABLE_SSH = false
      BUILTIN_SSH_SERVER_USER = ${cfg.sshUser}
      SSH_USER = ${cfg.sshUser}
      SSH_DOMAIN = ${cfg.domain}
      SSH_PORT = ${toString cfg.sshPort}
    ''}
    ${lib.optionalString (cfg.sshPort != null && cfg.sshBuiltin) ''
      START_SSH_SERVER = true
      SSH_LISTEN_HOST = 0.0.0.0
      SSH_LISTEN_PORT = ${toString cfg.sshPort}
    ''}

    [lfs]
    PATH = /data/lfs

    [repository]
    ROOT = /data/repositories
    ENABLE_PUSH_CREATE_USER = true
    ENABLE_PUSH_CREATE_ORG = true

    [git.timeout]
    MIGRATE = 3600
    MIRROR = 3600
    CLONE = 1200
    PULL = 1200
    GC = 120

    [log]
    ROOT_PATH = /data/log

    [log.console.router]
    LEVEL = Warn

    [ui]
    DEFAULT_THEME = ${cfg.theme.default}
    THEMES = ${cfg.theme.list}
  '';
in
{
  options.modules.forgejo = {
    enable = mkEnableOption "Forgejo git server setup";

    appName = mkOption {
      type = types.str;
      default = "Forgejo: Beyond Coding. We Forge.";
      description = "APP_NAME shown in the Forgejo UI.";
    };

    uid = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = ''
        User ID for the Forgejo service (null = let the system assign). Pin
        this when repositories live on shared/persistent storage whose
        on-disk ownership must stay stable across rebuilds — a uid drift will
        make Forgejo unable to read its own repos.
      '';
    };

    gid = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "Group ID for the Forgejo service (null = let the system assign).";
    };

    dataDir = mkOption {
      type = types.str;
      description = "Directory to store data.";
      default = "/var/lib/forgejo";
    };

    domain = mkOption {
      type = types.str;
      example = "git.example.com";
      description = "Domain name for the Forgejo instance.";
    };

    httpPort = mkOption {
      type = types.int;
      default = 3000;
      description = "HTTP port for the Forgejo service (behind the nginx front-end).";
    };

    sshPort = mkOption {
      type = types.nullOr types.port;
      default = null;
      description = ''
        Port that appears in clone URLs for git over SSH. Independent of where
        the SSH endpoint actually runs; see `sshBuiltin` for Forgejo's bundled
        server vs. an external one (typically the host's openssh routing the
        git user via authorized_keys forced commands). Setting this to null
        suppresses SSH URL advertisement entirely (HTTPS clone only).
      '';
    };

    sshUser = mkOption {
      type = types.str;
      default = "git";
      description = ''
        Username that appears in SSH clone URLs (the `<user>@host` portion).
        The actual server-side user is determined by whatever is serving SSH
        (Forgejo's built-in if `sshBuiltin = true`, or the host's openssh
        otherwise). On hosts that route through openssh with
        `Match User git,gitea`, either value here works.
      '';
    };

    sshBuiltin = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to run Forgejo's built-in SSH server inside the container.
        When false (default) only URL-display settings
        (SSH_USER/SSH_PORT/SSH_DOMAIN) are emitted and something else —
        typically the host's openssh — is assumed to handle the actual SSH
        endpoint. Requires `sshPort` to be non-null.
      '';
    };

    acmeHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        ACME certificate name to use for the nginx vhost (see
        `security.acme.certs`). If null, TLS is not configured here.
      '';
    };

    containerRuntime = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "runsc";
      description = ''
        OCI runtime to pass to podman as `--runtime` for the container shape.
        null uses podman's default (crun/runc). Set to a sandboxed runtime
        such as "runsc" (gVisor) for stronger isolation — you are responsible
        for installing and registering that runtime on the host.
      '';
    };

    containerExtraOptions = mkOption {
      type = types.listOf types.str;
      default = [ "--network=host" ];
      description = ''
        Extra options passed to podman run for the container shape. The
        default uses host networking so the loopback proxyPass from nginx
        reaches the container directly.
      '';
    };

    useUnixSocket = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether the native (asContainer = false) shape listens on a unix
        socket instead of TCP. Ignored for the container shape.
      '';
    };

    unixSocket = mkOption {
      type = types.str;
      default = "/run/forgejo/forgejo.sock";
      description = "Path to the unix socket file.";
    };

    database = {
      type = mkOption {
        type = types.enum [
          "sqlite3"
          "mysql"
          "postgres"
        ];
        example = "postgres";
        default = "sqlite3";
        description = "Database engine to use.";
      };

      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Database host address.";
      };

      sslMode = mkOption {
        type = types.str;
        default = "disable";
        example = "require";
        description = ''
          SSL_MODE for the container-shape database connection (postgres/mysql).
          Defaults to "disable", which is correct for the documented default of
          a loopback/socket-local database. If you point `database.host` at a
          remote host, set this to "require"/"verify-ca"/"verify-full" so the
          DB credentials and repository metadata are not sent in cleartext.
          Ignored for the sqlite3 engine and for the native (asContainer =
          false) shape, which uses the upstream module's own default.
        '';
      };

      port = mkOption {
        type = types.port;
        default =
          if cfg.database.type == "postgres" then
            5432
          else if cfg.database.type == "mysql" then
            3306
          else
            0;
        defaultText = literalExpression ''if type == "postgres" then 5432 else 3306'';
        description = "Database host port.";
      };

      name = mkOption {
        type = types.str;
        default = "forgejo";
        description = "Database name.";
      };

      user = mkOption {
        type = types.str;
        default = "forgejo";
        description = "Database user.";
      };

      password = mkOption {
        type = types.str;
        default = "";
        description = ''
          The password corresponding to {option}`database.user`.
          Warning: this is stored in cleartext in the Nix store!
          Use {option}`database.passwordFile` instead.
        '';
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/secrets/forgejo-dbpassword";
        description = ''
          A file containing the password corresponding to
          {option}`database.user`. Read at deploy time and substituted into
          app.ini, so the password never enters the Nix store.
        '';
      };

      socket = mkOption {
        type = types.nullOr types.path;
        default = "/run/postgresql";
        description = "Path to the unix socket file to use for authentication.";
      };

      path = mkOption {
        type = types.str;
        default = "${cfg.dataDir}/data/forgejo.db";
        defaultText = literalExpression ''"''${dataDir}/data/forgejo.db"'';
        description = "Path to the sqlite3 database file.";
      };

      createDatabase = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to create a local database automatically (native shape).";
      };

      configureLocalAuth = mkOption {
        type = types.bool;
        default = false;
        description = ''
          When true and type == "postgres", add local peer/ident
          authentication rules and an ident map to the host's
          `services.postgresql` so the forgejo system user can connect over
          the local socket without a password. Leave false if you manage
          Postgres authentication elsewhere.
        '';
      };
    };

    theme = {
      default = mkOption {
        type = types.str;
        default = "forgejo-auto";
        description = "Default theme name for the Forgejo UI.";
      };
      list = mkOption {
        type = types.str;
        default = "forgejo-auto,forgejo-light,forgejo-dark";
        description = "Comma-separated list of available themes.";
      };
    };

    asContainer = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to run Forgejo in a podman container or via native services.forgejo.";
    };

    oidc = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable automatic OIDC authentication-source configuration.";
      };

      clientSecretFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to file containing the OIDC client secret.";
      };

      discoveryUrl = mkOption {
        type = types.str;
        default = "";
        example = "https://idp.example.com/realms/main/.well-known/openid-configuration";
        description = "OIDC auto-discovery URL.";
      };

      clientId = mkOption {
        type = types.str;
        default = "forgejo";
        description = "OIDC client ID.";
      };

      scopes = mkOption {
        type = types.str;
        default = "openid profile email";
        description = "OIDC scopes.";
      };

      authSourceName = mkOption {
        type = types.str;
        default = "oidc";
        description = "Name for the OIDC authentication source.";
      };

      groupClaimName = mkOption {
        type = types.str;
        default = "";
        example = "groups";
        description = "Name of the claim in the OIDC token that contains group memberships.";
      };

      adminGroup = mkOption {
        type = types.str;
        default = "";
        description = "Group name that grants admin privileges in Forgejo.";
      };

      restrictedGroup = mkOption {
        type = types.str;
        default = "";
        description = "Group name that marks users as restricted in Forgejo.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.database.type != "sqlite3" || cfg.database.path != null;
          message = "Database path must be set when using SQLite";
        }
        {
          assertion =
            (cfg.database.type == "sqlite3")
            || (cfg.database.passwordFile != null || cfg.database.password != "");
          message = "Either database password or passwordFile must be set for MySQL/PostgreSQL";
        }
        {
          assertion = (cfg.database.type == "sqlite3") || cfg.database.host != "";
          message = "Database host must be set for MySQL/PostgreSQL";
        }
        {
          assertion = (cfg.database.type == "sqlite3") || cfg.database.name != "";
          message = "Database name must be set for MySQL/PostgreSQL";
        }
        {
          assertion = (cfg.database.type == "sqlite3") || cfg.database.user != "";
          message = "Database user must be set for MySQL/PostgreSQL";
        }
      ];

      # Force pubkey auth options off for the forgejo user so that
      # authorized_keys forced-commands behave predictably when git-over-ssh is
      # routed through the host's openssh.
      services.openssh.extraConfig = ''
        Match User forgejo
          PubkeyAuthOptions none
      '';

      services.nginx = {
        enable = true;
        virtualHosts."${cfg.domain}" = mkMerge [
          {
            locations."/" = {
              proxyPass =
                if cfg.asContainer then
                  "http://127.0.0.1:${toString cfg.httpPort}"
                else if cfg.useUnixSocket then
                  "http://unix:${cfg.unixSocket}"
                else
                  "http://localhost:${toString cfg.httpPort}";
              proxyWebsockets = true;
              extraConfig = ''
                client_max_body_size 512M;
                proxy_read_timeout        1h;
                chunked_transfer_encoding on;
                # Stream git smart-HTTP responses instead of buffering them.
                # With proxy_buffering on (the default), nginx buffers the whole
                # upload-pack response and truncates the tail when flushing to a
                # remote (latency > 0) client — git aborts with "early EOF /
                # unexpected disconnect while reading sideband packet". Loopback
                # clients are unaffected, which is why this only bites cross-host
                # fetches (e.g. a mirror/backup daemon cloning over the network).
                proxy_buffering off;
                proxy_request_buffering off;
              '';
            };
          }
          (mkIf (cfg.acmeHost != null) {
            forceSSL = true;
            useACMEHost = cfg.acmeHost;
          })
        ];
      };

      # Optional local Postgres auth wiring for the forgejo system user over the
      # unix socket. Uses upstream services.postgresql string options.
      services.postgresql = mkIf (cfg.database.type == "postgres" && cfg.database.configureLocalAuth) {
        identMap = ''
          forgejo-users ${cfg.database.user} ${cfg.database.user}
        '';
        authentication = ''
          local ${cfg.database.name} ${cfg.database.user} peer
          local ${cfg.database.name} all ident map=forgejo-users
        '';
      };

      users = {
        users.forgejo = mkIf (!cfg.asContainer && cfg.uid != null) {
          uid = mkDefault cfg.uid;
        };
        groups.forgejo = mkIf (!cfg.asContainer && cfg.gid != null) {
          gid = mkDefault cfg.gid;
        };
      };

      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 forgejo forgejo - -"
        "d ${cfg.dataDir}/custom 0750 forgejo forgejo - -"
        "d ${cfg.dataDir}/custom/conf 0750 forgejo forgejo - -"
        "d ${cfg.dataDir}/data 0750 forgejo forgejo - -"
        "d ${cfg.dataDir}/log 0750 forgejo forgejo - -"
        "d ${cfg.dataDir}/tmp 0750 forgejo forgejo - -"
      ]
      ++ lib.optionals cfg.useUnixSocket [
        "d /run/forgejo 0755 forgejo forgejo - -"
      ];

      networking.firewall.allowedTCPPorts = lib.mkIf (cfg.sshPort != null && cfg.sshBuiltin) [
        cfg.sshPort
      ];
    }

    (mkIf cfg.asContainer {
      users.users.forgejo = {
        isSystemUser = true;
        group = "forgejo";
        home = cfg.dataDir;
        description = "Forgejo Service";
      }
      // lib.optionalAttrs (cfg.uid != null) { uid = cfg.uid; };
      users.groups.forgejo = lib.optionalAttrs (cfg.gid != null) { gid = cfg.gid; };

      # Templating step: read the DB password from the runtime file and sed it
      # into the app.ini placeholder, then lock down ownership. This keeps the
      # password out of the Nix store while still shipping a fully-rendered
      # config into the data volume.
      systemd.services.podman-forgejo.preStart = lib.mkAfter ''
        uid=${containerUid}
        gid=${containerGid}
        mkdir -p ${cfg.dataDir}/custom/conf
        DB_PASS=$(cat ${toString cfg.database.passwordFile} 2>/dev/null || echo "")
        ${pkgs.gnused}/bin/sed "s|\`FORGEJO_DB_PASSWD\`|$DB_PASS|g" ${appIni} > ${cfg.dataDir}/custom/conf/app.ini
        chmod 600 ${cfg.dataDir}/custom/conf/app.ini
        chown "$uid:$gid" \
          ${cfg.dataDir} \
          ${cfg.dataDir}/custom \
          ${cfg.dataDir}/custom/conf \
          ${cfg.dataDir}/custom/conf/app.ini
      '';

      virtualisation.oci-containers.backend = "podman";
      virtualisation.oci-containers.containers.forgejo = {
        imageFile = forgejoImage;
        image = "forgejo:latest";
        user = "${containerUid}:${containerGid}";
        extraOptions =
          lib.optionals (cfg.containerRuntime != null) [ "--runtime=${cfg.containerRuntime}" ]
          ++ cfg.containerExtraOptions;
        volumes = [
          "${cfg.dataDir}:/data"
        ];
      };
    })

    (mkIf (!cfg.asContainer) {
      services.forgejo = {
        enable = true;
        stateDir = cfg.dataDir;
        lfs.enable = true;
        settings = {
          server =
            if cfg.useUnixSocket then
              {
                PROTOCOL = "http+unix";
                HTTP_ADDR = cfg.unixSocket;
                DOMAIN = cfg.domain;
                ROOT_URL = "https://${cfg.domain}";
              }
            else
              {
                PROTOCOL = "http";
                HTTP_ADDR = "0.0.0.0";
                HTTP_PORT = cfg.httpPort;
                DOMAIN = cfg.domain;
                ROOT_URL = "https://${cfg.domain}";
              };
        };
        database = forgejoDbCfg;
      };
    })

    (mkIf cfg.oidc.enable {
      assertions = [
        {
          assertion = cfg.oidc.clientSecretFile != null;
          message = "OIDC client secret file must be provided when OIDC is enabled";
        }
        {
          assertion = cfg.oidc.discoveryUrl != "";
          message = "OIDC discovery URL must be provided when OIDC is enabled";
        }
      ];

      # Oneshot that waits for both Forgejo and the OIDC discovery endpoint,
      # creates the OAuth login source via the admin CLI (idempotent), then
      # flips is_sync_enabled directly in the DB to enable auto-registration.
      systemd.services.forgejo-oidc-setup = {
        description = "Setup Forgejo OIDC authentication source";
        after = [ "forgejo.service" ];
        wants = [ "forgejo.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "forgejo";
          Group = "forgejo";
        };
        script = ''
          echo "Waiting for Forgejo to be ready..."

          if [ "${toString cfg.useUnixSocket}" = "1" ]; then
            echo "Using Unix socket: ${cfg.unixSocket}"
            CURL_CMD="${pkgs.curl}/bin/curl -sf --unix-socket ${cfg.unixSocket} http://localhost/"
          else
            echo "Using HTTP port: ${toString cfg.httpPort}"
            CURL_CMD="${pkgs.curl}/bin/curl -sf http://localhost:${toString cfg.httpPort}/"
          fi

          for i in {1..30}; do
            if $CURL_CMD > /dev/null 2>&1; then
              echo "Forgejo is ready"
              break
            fi
            echo "Attempt $i/30: Forgejo not ready yet, waiting..."
            sleep 2
          done

          echo "Checking OIDC provider connectivity..."
          OIDC_READY=0
          for i in {1..60}; do
            if ${pkgs.curl}/bin/curl -sf "${cfg.oidc.discoveryUrl}" > /dev/null 2>&1; then
              echo "OIDC provider is reachable"
              OIDC_READY=1
              break
            fi
            echo "Attempt $i/60: OIDC provider not reachable yet, waiting..."
            sleep 2
          done
          if [ "$OIDC_READY" -eq 0 ]; then
            echo "ERROR: Cannot reach OIDC discovery endpoint after 60 attempts: ${cfg.oidc.discoveryUrl}"
            exit 1
          fi

          CLIENT_SECRET=$(cat ${toString cfg.oidc.clientSecretFile} | tr -d '\n\r ')

          echo "Checking if OAuth source exists..."
          if ${pkgs.forgejo}/bin/forgejo --config ${cfg.dataDir}/custom/conf/app.ini admin auth list | grep -q "${cfg.oidc.authSourceName}"; then
            echo "OAuth source '${cfg.oidc.authSourceName}' already exists, skipping creation"
          else
            echo "Creating OIDC authentication source..."
            # The secret is passed via --secret because Forgejo's `admin auth
            # add-oauth` accepts the client secret only as a CLI argument (no
            # env-var, stdin, or --secret-file input exists upstream). It is
            # therefore briefly visible in /proc/<pid>/cmdline for the lifetime
            # of this single exec. The unit runs as the unprivileged `forgejo`
            # user and the secret is never written to the journal (we never
            # echo it or SELECT the login_source cfg column). If your host is
            # multi-tenant, consider `fs.protected_hardlinks` / a hidepid mount
            # so other local users cannot read this process's cmdline.
            ${pkgs.forgejo}/bin/forgejo --config ${cfg.dataDir}/custom/conf/app.ini admin auth add-oauth \
              --name "${cfg.oidc.authSourceName}" \
              --provider "openidConnect" \
              --key "${cfg.oidc.clientId}" \
              --secret "$CLIENT_SECRET" \
              --auto-discover-url "${cfg.oidc.discoveryUrl}" \
              --scopes "${cfg.oidc.scopes}" \
              ${
                lib.optionalString (
                  cfg.oidc.groupClaimName != ""
                ) "--group-claim-name \"${cfg.oidc.groupClaimName}\""
              } \
              ${lib.optionalString (cfg.oidc.adminGroup != "") "--admin-group \"${cfg.oidc.adminGroup}\""} \
              ${lib.optionalString (
                cfg.oidc.restrictedGroup != ""
              ) "--restricted-group \"${cfg.oidc.restrictedGroup}\""}

            echo "OIDC authentication source created successfully"

            # NOTE: do NOT SELECT the login_source `cfg` column here. Forgejo
            # stores the OAuth client secret inside that JSON blob, so dumping
            # it to stdout would persist the secret in the systemd journal
            # (readable by root and the adm/systemd-journal groups) across
            # reboots. We only touch non-secret columns and never print row
            # contents.
            echo "Attempting to enable auto-registration and account linking..."
            ${pkgs.postgresql}/bin/psql -h /run/postgresql -U ${cfg.database.user} -d ${cfg.database.name} -c "
              UPDATE login_source
              SET is_sync_enabled = true
              WHERE name = '${cfg.oidc.authSourceName}';
            " && echo "Successfully enabled auto-registration!" || echo "Note: Could not enable auto-registration via database"
          fi
        '';
      };
    })
  ]);
}
