{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.modules.services.pgadmin;

  hostPostgresPackage = config.services.postgresql.package;
in
{
  options.modules.services.pgadmin = {
    enable = mkEnableOption "pgAdmin in a host-socket container";

    createUser = mkEnableOption "creating a login role in the host database";

    enableNginx = mkOption {
      type = types.bool;
      default = true;
      description = "Publish pgAdmin through a local nginx reverse proxy.";
    };

    domain = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "pgadmin.example.com";
      description = "Virtual-host name for the nginx reverse proxy.";
    };

    acmeHost = mkOption {
      type = types.nullOr types.str;
      default = cfg.domain;
      example = "pgadmin.example.com";
      description = ''
        ACME certificate name to use for TLS. Defaults to `domain`.
        Set to null to serve plain HTTP (e.g. behind another TLS terminator).
      '';
    };

    operatorUser = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "alice";
      description = ''
        Optional human account to add to the `pgadmin` group so it can read
        the (mode 0700) data directory. Leave null to grant no extra access.
      '';
    };

    passwordFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to a file containing the initial pgAdmin web login password.
        Bind-mounted into the container. Provision it with your secrets tool.
      '';
    };

    pgadminPasswordFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to a file containing the password for the `pgadmin` PostgreSQL
        role. Only required when `createUser` is true.
      '';
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/pgadmin";
      description = "Host directory holding pgAdmin's persistent state.";
    };

    port = mkOption {
      type = types.port;
      default = 5050;
      description = "TCP port pgAdmin listens on inside the container.";
    };

    email = mkOption {
      type = types.str;
      default = "admin@example.com";
      description = "Initial pgAdmin login email.";
    };

    uid = mkOption {
      type = types.int;
      default = 5050;
      description = "UID owning the data directory on the host.";
    };

    gid = mkOption {
      type = types.int;
      default = cfg.uid;
      description = "GID owning the data directory on the host.";
    };

    containerNetwork = {
      hostAddress = mkOption {
        type = types.str;
        default = "192.168.202.1";
        description = "Host side of the container veth pair.";
      };
      localAddress = mkOption {
        type = types.str;
        default = "192.168.202.2";
        description = "Container side of the container veth pair.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf (cfg.enableNginx && cfg.domain != null) {
      services.nginx.enable = true;
      services.nginx.virtualHosts.${cfg.domain} = mkMerge [
        {
          locations."/" = {
            proxyPass = "http://${cfg.containerNetwork.localAddress}:${toString cfg.port}/";
            proxyWebsockets = true;
            recommendedProxySettings = true;
          };
        }
        (mkIf (cfg.acmeHost != null) {
          forceSSL = true;
          useACMEHost = cfg.acmeHost;
        })
      ];
    })

    {
      assertions = [
        {
          assertion = cfg.passwordFile != null;
          message = "modules.services.pgadmin: passwordFile must be set when enabled.";
        }
        {
          assertion = !cfg.enableNginx || cfg.domain != null;
          message = "modules.services.pgadmin: domain must be set when enableNginx is true.";
        }
        {
          assertion = cfg.pgadminPasswordFile != null || !cfg.createUser;
          message = "modules.services.pgadmin: pgadminPasswordFile must be set when createUser is true.";
        }
      ];

      systemd.services."container@pgadmin" = {
        after = [ "postgresql.service" ];
        requires = [ "postgresql.service" ];
      };

      containers.pgadmin = {
        autoStart = true;
        privateNetwork = true;
        inherit (cfg.containerNetwork) hostAddress localAddress;

        config = _: {
          services.pgadmin = {
            enable = true;
            initialEmail = cfg.email;
            initialPasswordFile = cfg.passwordFile;
            inherit (cfg) port;
            openFirewall = true;
            settings = {
              DEFAULT_SERVER = "0.0.0.0";
            };
          };

          services.postgresql.package = hostPostgresPackage;

          system.stateVersion = "24.11";
          networking.nameservers = [ cfg.containerNetwork.hostAddress ];
          networking.firewall.allowedTCPPorts = [ cfg.port ];
        };

        bindMounts = {
          "${cfg.passwordFile}" = {
            hostPath = cfg.passwordFile;
          };
          "${cfg.dataDir}" = {
            hostPath = cfg.dataDir;
          };
          "/run/postgresql" = {
            hostPath = "/run/postgresql";
            isReadOnly = false;
          };
        };
      };

      networking.firewall.interfaces."ve-pgadmin" = {
        allowedUDPPorts = [ 53 ];
        allowedTCPPorts = [ 53 ];
      };

      users.users.pgadmin = {
        inherit (cfg) uid;
        group = "pgadmin";
        isSystemUser = true;
      };

      users.groups.pgadmin = {
        inherit (cfg) gid;
        members = optional (cfg.operatorUser != null) cfg.operatorUser ++ [ "pgadmin" ];
      };

      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0700 ${toString cfg.uid} ${toString cfg.gid} - -"
      ];

      systemd.services.pgadmin-postgres-setup = mkIf cfg.createUser {
        description = "Provision PostgreSQL login role for pgAdmin";
        wantedBy = [ "multi-user.target" ];
        before = [ "container@pgadmin.service" ];
        after = [ "postgresql.service" ];
        requires = [ "postgresql.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "postgres";
          Group = "postgres";
        };
        script = ''
          while ! ${pkgs.postgresql}/bin/pg_isready -q; do
            sleep 1
          done

          # Feed all SQL over stdin -- NEVER put the password on the psql
          # command line (argv is world-readable via /proc/<pid>/cmdline on a
          # default NixOS host, so `-c "... PASSWORD '$PASSWORD' ..."` would
          # leak the DB credential to any local user during this oneshot).
          #
          # psql reads the secret itself: `\set pw ` + a backtick command
          # captures the file contents into a psql variable (its output never
          # appears on any process's argv). `:'pw'` then expands to a properly
          # escaped SQL string literal, which also prevents SQL injection if the
          # password contains quotes. Variable interpolation does not happen
          # inside dollar-quoted DO blocks, so we use a \gexec-driven create
          # plus a plain ALTER instead.
          ${pkgs.postgresql}/bin/psql -v ON_ERROR_STOP=1 --no-psqlrc postgres <<'SQL'
          \set pw `cat ${cfg.pgadminPasswordFile}`
          SELECT 'CREATE ROLE pgadmin LOGIN'
            WHERE NOT EXISTS (
              SELECT FROM pg_catalog.pg_roles WHERE rolname = 'pgadmin'
            )
          \gexec
          ALTER ROLE pgadmin WITH LOGIN PASSWORD :'pw' CREATEDB CREATEROLE;
          SQL
        '';
      };
    }
  ]);
}
