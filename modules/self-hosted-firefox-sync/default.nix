{
  config,
  pkgs,
  lib,
  ...
}:

with lib;
let
  cfg = config.modules.services.firefox-sync;

  entrypoint = pkgs.writeShellScript "firefox-sync-entrypoint" ''
    set -e
    mkdir -p /var/lib/mysql /run/mysqld
    chown -R mysql:mysql /var/lib/mysql /run/mysqld

    if [ ! -d /var/lib/mysql/mysql ]; then
      ${pkgs.mariadb}/bin/mysql_install_db --user=mysql --datadir=/var/lib/mysql
    fi

    # Bind to loopback only: the database never leaves the container's own
    # network namespace, syncserver reaches it on 127.0.0.1 from inside.
    ${pkgs.mariadb}/bin/mariadbd --user=mysql --datadir=/var/lib/mysql --bind-address=127.0.0.1 &
    mariadb_pid=$!

    # Never `wait` here: the script ends in `exec syncserver`, so mariadbd is
    # meant to keep running as a child of PID 1, not to be reaped. The pid is
    # only used to abort early if mariadbd dies during the readiness wait,
    # instead of spinning the full 30s and failing on the first SQL statement.
    for i in $(seq 1 30); do
      if ${pkgs.mariadb}/bin/mysqladmin ping --silent 2>/dev/null; then
        break
      fi
      if ! kill -0 "$mariadb_pid" 2>/dev/null; then
        echo "mariadbd exited before becoming ready" >&2
        exit 1
      fi
      sleep 1
    done

    ${pkgs.mariadb}/bin/mysql -u root <<'SQL'
    ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD(''');
    CREATE DATABASE IF NOT EXISTS syncstorage;
    CREATE DATABASE IF NOT EXISTS tokenserver;
    FLUSH PRIVILEGES;
    SQL

    exec ${pkgs.syncstorage-rs}/bin/syncserver
  '';

  passwdFile = pkgs.writeTextDir "etc/passwd" ''
    root:x:0:0:root:/root:/bin/bash
    mysql:x:${toString cfg.uid}:${toString cfg.gid}:MariaDB:/var/lib/mysql:/bin/false
  '';
  groupFile = pkgs.writeTextDir "etc/group" ''
    root:x:0:
    mysql:x:${toString cfg.gid}:
  '';

  nodeUrl = "https://ffsync.${cfg.domain}";

  firefoxSyncImage = pkgs.dockerTools.buildLayeredImage {
    name = "firefox-sync";
    tag = "latest";
    contents = with pkgs; [
      syncstorage-rs
      mariadb
      bash
      coreutils
      gnugrep
      gnused
      cacert
      passwdFile
      groupFile
    ];
    config = {
      Cmd = [ "${entrypoint}" ];
      Env = [
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "SYNC_HUMAN_LOGS=1"
        "SYNC_HOST=0.0.0.0"
        "SYNC_SYNCSTORAGE__DATABASE_URL=mysql://root@127.0.0.1:3306/syncstorage"
        "SYNC_TOKENSERVER__ENABLED=true"
        "SYNC_TOKENSERVER__NODE_TYPE=mysql"
        "SYNC_TOKENSERVER__DATABASE_URL=mysql://root@127.0.0.1:3306/tokenserver"
        "SYNC_TOKENSERVER__FXA_EMAIL_DOMAIN=api.accounts.firefox.com"
        "SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL=https://oauth.accounts.firefox.com/v1"
        "SYNC_TOKENSERVER__RUN_MIGRATIONS=true"
        "SYNC_TOKENSERVER__ADDITIONAL_BLOCKING_THREADS_FOR_FXA_REQUESTS=10"
        "SYNC_TOKENSERVER__NODE_CAPACITY_RELEASE_RATE=1"
      ];
    };
  };
in
{
  options.modules.services.firefox-sync = {
    enable = mkEnableOption "self-hosted Firefox Sync server (syncstorage-rs)";

    domain = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "example.com";
      description = ''
        Base domain. The sync server is served at `ffsync.<domain>`.
        Point your browser's `identity.sync.tokenserver.uri` at
        `https://ffsync.<domain>/1.0/sync/1.5`.
      '';
    };

    acmeHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "example.com";
      description = ''
        `security.acme` certificate name to use for the nginx vhost
        (`services.nginx.virtualHosts.<name>.useACMEHost`). You are
        responsible for provisioning that certificate elsewhere.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 8000;
      description = ''
        Port nginx proxies to. Must match what syncserver actually
        listens on. syncserver only accepts `--config` (no port
        flag/env), so changing this requires also passing a config
        file with the matching `port = ...`. The 8000 default is
        syncstorage-rs's hardcoded default, which is what the
        upstream binary binds to with no config.
      '';
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/firefox-sync";
      description = "Host directory bind-mounted into the container at /data.";
    };

    mariadbDataDir = mkOption {
      type = types.str;
      default = "/var/lib/firefox-sync/mariadb";
      description = "Host directory for the MariaDB datadir (bind-mounted at /var/lib/mysql).";
    };

    uid = mkOption {
      type = types.int;
      default = 990;
      description = ''
        User ID for the host `firefox-sync` user. This value is
        load-bearing in THREE places that must agree, or MariaDB
        cannot read its bind-mounted datadir: the host user, the
        0700 tmpfiles ownership of the data dirs, and the `mysql`
        entry baked into the image's /etc/passwd. The specific number
        is arbitrary -- pick any free uid -- but keep it consistent.
      '';
    };

    gid = mkOption {
      type = types.int;
      default = 990;
      description = "Group ID for the host `firefox-sync` group. See `uid`.";
    };

    secretsFile = mkOption {
      type = types.path;
      description = ''
        Path to an environment file supplying `SYNC_MASTER_SECRET`
        (a long random string; generate with e.g.
        `head -c 32 /dev/urandom | base64`). Passed to the container
        via podman `environmentFiles`. Any secret-management scheme
        works (agenix, sops-nix, a plain root-only file); the module
        only needs a readable path at activation time.
      '';
    };

    nodeCapacity = mkOption {
      type = types.int;
      default = 10;
      description = ''
        How many Firefox accounts the single storage node advertises to the
        tokenserver. Registered as node 1 (`https://ffsync.<domain>`) once
        the tokenserver has created its tables.
      '';
    };

    backend = mkOption {
      type = types.enum [
        "podman"
        "docker"
      ];
      default = "podman";
      description = ''
        OCI backend the container runs on; the unit is `<backend>-firefox-sync`
        and `virtualisation.oci-containers.backend` (one per host) is set to it.
      '';
    };
    extraPodmanOptions = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "--runtime=runsc" ];
      description = ''
        Extra flags appended to the podman run invocation. Use this to
        opt into a hardened OCI runtime such as gVisor
        (`--runtime=runsc`) if you have one registered on the host.
        The module defaults to the standard runc/crun runtime.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.domain != null;
        message = "modules.services.firefox-sync: domain must be set when firefox-sync is enabled";
      }
      {
        assertion = cfg.acmeHost != null;
        message = "modules.services.firefox-sync: acmeHost must be set when firefox-sync is enabled";
      }
    ];

    services.nginx.virtualHosts."ffsync.${cfg.domain}" = {
      forceSSL = true;
      useACMEHost = cfg.acmeHost;
      locations."/".proxyPass = "http://127.0.0.1:${toString cfg.port}/";
    };

    users = {
      users.firefox-sync = {
        inherit (cfg) uid;
        isSystemUser = true;
        group = "firefox-sync";
      };
      groups.firefox-sync.gid = cfg.gid;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 ${toString cfg.uid} ${toString cfg.gid} - -"
      "d ${cfg.mariadbDataDir} 0700 ${toString cfg.uid} ${toString cfg.gid} - -"
    ];

    systemd.services."${cfg.backend}-firefox-sync" = {
      preStart = lib.mkAfter ''
        mkdir -p ${cfg.dataDir} ${cfg.mariadbDataDir}
      '';
      postStart = ''
        mysql="${config.virtualisation.${cfg.backend}.package}/bin/${cfg.backend} exec -i firefox-sync ${pkgs.mariadb}/bin/mysql -u root tokenserver"
        ready() { $mysql -Ne 'SHOW TABLES' 2>/dev/null | grep -qx services; }
        until ready; do sleep 2; [ $SECONDS -gt 180 ] && break; done
        ready || { echo "firefox-sync: tokenserver tables never appeared, node not registered" >&2; exit 1; }
        $mysql <<'SQL'
        BEGIN;
        INSERT INTO services (service, pattern)
          SELECT 'sync-1.5', '{node}/1.5/{uid}'
          WHERE NOT EXISTS (SELECT 1 FROM services WHERE service = 'sync-1.5');
        SET @svc = (SELECT id FROM services WHERE service = 'sync-1.5');
        INSERT INTO nodes (id, service, node, available, current_load, capacity, downed, backoff)
          VALUES (1, @svc, '${nodeUrl}', ${toString cfg.nodeCapacity}, 0, ${toString cfg.nodeCapacity}, 0, 0)
          ON DUPLICATE KEY UPDATE service=@svc, node='${nodeUrl}', capacity=${toString cfg.nodeCapacity};
        COMMIT;
        SQL
      '';
    };

    virtualisation.oci-containers.backend = cfg.backend;
    virtualisation.oci-containers.containers.firefox-sync = {
      imageFile = firefoxSyncImage;
      image = "firefox-sync:latest";
      environmentFiles = [ cfg.secretsFile ];
      ports = [ "127.0.0.1:${toString cfg.port}:8000" ];
      extraOptions = cfg.extraPodmanOptions;
      volumes = [
        "${cfg.dataDir}:/data"
        "${cfg.mariadbDataDir}:/var/lib/mysql"
      ];
    };
  };
}
