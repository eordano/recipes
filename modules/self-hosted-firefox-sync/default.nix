# self-hosted-firefox-sync
#
# Run your own Firefox Sync (syncstorage-rs) bundled with its MariaDB backend
# in a single, hand-built OCI image. This deliberately avoids NixOS's
# `services.firefox-syncserver`; instead the container's entrypoint boots
# mariadbd, waits for it, creates the databases, then execs syncserver.
#
# Import this module, set `enable`, `domain`, `acmeHost`, and `secretsFile`.
#
# See README.md for the boot-DB-then-exec entrypoint pattern and the three
# traps this encodes (uid/gid agreement, the hardcoded 8000 port, and host
# networking).

{
  config,
  pkgs,
  lib,
  ...
}:

with lib;
let
  cfg = config.modules.services.firefox-sync;

  # Entrypoint: bring MariaDB up in the background, wait for it, create the
  # syncstorage/tokenserver databases, then hand the container's PID 1 to
  # syncserver via exec.
  entrypoint = pkgs.writeShellScript "firefox-sync-entrypoint" ''
    set -e
    mkdir -p /var/lib/mysql /run/mysqld
    chown -R mysql:mysql /var/lib/mysql /run/mysqld

    if [ ! -d /var/lib/mysql/mysql ]; then
      ${pkgs.mariadb}/bin/mysql_install_db --user=mysql --datadir=/var/lib/mysql
    fi

    # Bind to loopback only. Under `--network=host` the container shares the
    # host net namespace, so 0.0.0.0 would put 3306 on every routable
    # interface; syncserver (also host-networked) reaches it on 127.0.0.1.
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

  # The image has no real user database, so we ship one. The `mysql` uid/gid
  # here MUST equal cfg.uid/cfg.gid (see below) or mariadbd inside the
  # container cannot read the bind-mounted, host-owned datadir.
  passwdFile = pkgs.writeTextDir "etc/passwd" ''
    root:x:0:0:root:/root:/bin/bash
    mysql:x:${toString cfg.uid}:${toString cfg.gid}:MariaDB:/var/lib/mysql:/bin/false
  '';
  groupFile = pkgs.writeTextDir "etc/group" ''
    root:x:0:
    mysql:x:${toString cfg.gid}:
  '';

  firefoxSyncImage = pkgs.dockerTools.buildLayeredImage {
    name = "firefox-sync";
    tag = "latest";
    contents = with pkgs; [
      syncstorage-rs
      mariadb
      bash
      coreutils
      gnugrep
      cacert
      passwdFile
      groupFile
    ];
    config = {
      Cmd = [ "${entrypoint}" ];
      Env = [
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
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
        file with the matching `port = …`. The 8000 default is
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
        is arbitrary — pick any free uid — but keep it consistent.
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
        uid = cfg.uid;
        isSystemUser = true;
        group = "firefox-sync";
      };
      groups.firefox-sync.gid = cfg.gid;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 ${toString cfg.uid} ${toString cfg.gid} - -"
      "d ${cfg.mariadbDataDir} 0700 ${toString cfg.uid} ${toString cfg.gid} - -"
    ];

    systemd.services.podman-firefox-sync.preStart = lib.mkAfter ''
      mkdir -p ${cfg.dataDir} ${cfg.mariadbDataDir}
    '';

    virtualisation.oci-containers.backend = "podman";
    virtualisation.oci-containers.containers.firefox-sync = {
      imageFile = firefoxSyncImage;
      image = "firefox-sync:latest";
      environmentFiles = [ cfg.secretsFile ];
      extraOptions = [
        "--network=host"
      ] ++ cfg.extraPodmanOptions;
      volumes = [
        "${cfg.dataDir}:/data"
        "${cfg.mariadbDataDir}:/var/lib/mysql"
      ];
    };
  };
}
