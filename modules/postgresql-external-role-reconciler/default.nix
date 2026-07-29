# postgresql-external-role-reconciler
#
# Drive role passwords, ownership and read-only grants into a PostgreSQL server
# this host does NOT run: a managed cloud instance, a Patroni cluster reached
# through a leader proxy, a database VM on the other side of a VPN.
#
# Upstream `services.postgresql.ensureUsers` cannot do this — its whole config
# block is `mkIf cfg.enable` (nixpkgs
# nixos/modules/services/databases/postgresql.nix:609) and the unit that applies
# it, `postgresql-setup`, `requires`/`after` the local `postgresql.service` and
# talks to the local unix socket (ibid. :870-885). It also has no file-based
# password input at all: the only way in is `ensureClauses.password`, a literal
# Nix string that lands in a world-readable store path (ibid. :473, :74-87).
#
# One oneshot per role. Secrets arrive through systemd `LoadCredential`, so the
# service user never needs read access to the secret file and the unit can run
# as a `DynamicUser`. The cleartext password is handed to psql through the
# environment and psql's `\getenv` (PostgreSQL >= 14), never on argv.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.postgresql-external-roles;

  inherit (lib)
    concatStringsSep
    mapAttrsToList
    mkIf
    mkOption
    optionalString
    types
    ;

  # Every identifier this module emits is double-quoted, and every identifier is
  # also checked against `identPattern` by an assertion — the two together are
  # what keep a config value from becoming SQL.
  q = s: ''"${s}"'';
  identPattern = "[A-Za-z_][A-Za-z0-9_$]*";
  badIdent = s: builtins.match identPattern s == null;

  psql = "${cfg.package}/bin/psql -X -q -v ON_ERROR_STOP=1";

  connEnv = ''
    export PGHOST=${lib.escapeShellArg cfg.host}
    export PGPORT=${toString cfg.port}
    export PGUSER=${lib.escapeShellArg cfg.superuser}
    export PGDATABASE=${lib.escapeShellArg cfg.maintenanceDatabase}
    export PGSSLMODE=${cfg.sslMode}
    export PGCONNECT_TIMEOUT=${toString cfg.connectTimeoutSec}
    export PGAPPNAME=pg-role-reconciler
  ''
  + optionalString (cfg.superuserPasswordFile != null) ''
    PGPASSWORD=$(cat "$CREDENTIALS_DIRECTORY/superuser")
    export PGPASSWORD
  '';

  # Fail loudly and early if the server is unreachable, instead of emitting a
  # psql connection error per statement.
  waitBlock = ''
    deadline=$(( $(date +%s) + ${toString cfg.readyTimeoutSec} ))
    until ${cfg.package}/bin/pg_isready -q; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "pg-role: $PGHOST:$PGPORT not accepting connections after ${toString cfg.readyTimeoutSec}s" >&2
        exit 1
      fi
      sleep 2
    done
  '';

  ensureRoleSQL =
    name: role:
    ''
      DO $do$
      BEGIN
        CREATE ROLE ${q name};
      EXCEPTION WHEN duplicate_object THEN
        NULL;
      END
      $do$;
    ''
    + optionalString (role.clauses != [ ]) ''
      ALTER ROLE ${q name} WITH ${concatStringsSep " " role.clauses};
    ''
    + concatStringsSep "" (
      map (db: ''
        ALTER DATABASE ${q db} OWNER TO ${q name};
      '') role.ownsDatabases
    )
    + concatStringsSep "" (
      map (db: ''
        REVOKE CONNECT ON DATABASE ${q db} FROM PUBLIC;
      '') role.revokePublicConnect
    );

  # A separate psql session, because it is the only one that carries the
  # cleartext. `SET log_statement` keeps the ALTER out of the server log even if
  # the server is globally configured to log DDL.
  passwordSQL = name: ''
    ${optionalString cfg.suppressStatementLogging ''
      SET log_statement = 'none';
      SET log_min_duration_statement = -1;
    ''}\getenv pgrolepw PG_ROLE_PASSWORD
    ALTER ROLE ${q name} WITH PASSWORD :'pgrolepw';
  '';

  readOnlySQL =
    role: ro:
    concatStringsSep "" (
      map (
        schema:
        ''
          GRANT USAGE ON SCHEMA ${q schema} TO ${q role};
          GRANT SELECT ON ALL TABLES IN SCHEMA ${q schema} TO ${q role};
        ''
        + optionalString ro.sequences ''
          GRANT SELECT ON ALL SEQUENCES IN SCHEMA ${q schema} TO ${q role};
        ''
        + optionalString (ro.defaultPrivilegesFrom != null) ''
          ALTER DEFAULT PRIVILEGES FOR ROLE ${q ro.defaultPrivilegesFrom} IN SCHEMA ${q schema}
            GRANT SELECT ON TABLES TO ${q role};
        ''
        + optionalString (ro.defaultPrivilegesFrom != null && ro.sequences) ''
          ALTER DEFAULT PRIVILEGES FOR ROLE ${q ro.defaultPrivilegesFrom} IN SCHEMA ${q schema}
            GRANT SELECT ON SEQUENCES TO ${q role};
        ''
      ) ro.schemas
    );

  # SQL goes to the store as files and is run with `psql -f`. No heredocs (whose
  # terminator would have to survive Nix indentation stripping) and no secret
  # ever reaches these files — the password session only names an environment
  # variable for psql to read.
  sqlFile =
    name: suffix: text:
    pkgs.writeText "pg-role-${name}-${suffix}.sql" text;

  roleScript = name: role: ''
    set -euo pipefail
    ${connEnv}
    ${waitBlock}

    echo "pg-role: reconciling ${name} on $PGHOST:$PGPORT"
    ${psql} -f ${sqlFile name "role" (ensureRoleSQL name role)}

    ${optionalString (role.passwordFile != null) ''
      PG_ROLE_PASSWORD=$(cat "$CREDENTIALS_DIRECTORY/password")
      export PG_ROLE_PASSWORD
      ${psql} -f ${sqlFile name "password" (passwordSQL name)}
      unset PG_ROLE_PASSWORD
    ''}

    ${concatStringsSep "" (
      lib.imap0 (i: ro: ''
        ${psql} -f ${
          sqlFile name "connect-${toString i}" ''
            GRANT CONNECT ON DATABASE ${q ro.database} TO ${q name};
          ''
        }
        ${psql} -d ${lib.escapeShellArg ro.database} -f ${
          sqlFile name "readonly-${toString i}" (readOnlySQL name ro)
        }
      '') role.readOnly
    )}

    ${concatStringsSep "" (
      mapAttrsToList (db: sql: ''
        ${psql} -d ${lib.escapeShellArg db} -f ${sqlFile name "extra-${db}" sql}
      '') role.extraSQL
    )}

    echo "pg-role: ${name} reconciled"
  '';

  roleOpts = types.submodule (
    { name, ... }:
    {
      options = {
        passwordFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          example = "/run/secrets/db-password-app";
          description = ''
            File holding this role's cleartext password. Loaded via systemd
            `LoadCredential`, so it is read by PID 1 as root — the service user
            needs no access to it and it may stay `0400 root:root`.

            Null means "manage grants and clauses but never touch the password".
          '';
        };

        clauses = mkOption {
          type = types.listOf types.str;
          default = [
            "LOGIN"
            "NOSUPERUSER"
            "NOCREATEDB"
            "NOCREATEROLE"
            "NOREPLICATION"
          ];
          example = [
            "LOGIN"
            "CONNECTION LIMIT 120"
          ];
          description = ''
            `ALTER ROLE <name> WITH <clauses>` applied on every run. This is
            desired state, not a one-time create: attributes drift back on each
            reconcile. Emitted verbatim, so keep it to literal SQL role
            attributes.
          '';
        };

        ownsDatabases = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "app" ];
          description = "Databases to `ALTER DATABASE ... OWNER TO` this role.";
        };

        revokePublicConnect = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "app" ];
          description = ''
            Databases to `REVOKE CONNECT ... FROM PUBLIC` on. PostgreSQL grants
            CONNECT to PUBLIC on every new database; without this any role that
            can authenticate can open any database.
          '';
        };

        readOnly = mkOption {
          default = [ ];
          description = "Databases this role gets read-only access to.";
          type = types.listOf (
            types.submodule {
              options = {
                database = mkOption {
                  type = types.str;
                  description = "Database to grant read-only access to.";
                };
                schemas = mkOption {
                  type = types.listOf types.str;
                  default = [ "public" ];
                  description = "Schemas within that database.";
                };
                sequences = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Also grant SELECT on sequences (needed by ORMs that read currval).";
                };
                defaultPrivilegesFrom = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  example = "app";
                  description = ''
                    Role whose FUTURE objects should also be readable, via
                    `ALTER DEFAULT PRIVILEGES FOR ROLE <this>`.

                    Leaving this null is the classic bug: `GRANT SELECT ON ALL
                    TABLES` is a point-in-time snapshot, so the next migration's
                    table is invisible to the reader. Default privileges are keyed
                    on the *creating* role, so this must name whoever runs the
                    migrations, not the reader.
                  '';
                };
              };
            }
          );
        };

        extraSQL = mkOption {
          type = types.attrsOf types.lines;
          default = { };
          example = lib.literalExpression ''
            { app = "GRANT USAGE ON SCHEMA reporting TO \"reader\";"; }
          '';
          description = ''
            Extra SQL keyed by database name, run in that database after the
            grants above. Emitted verbatim — the identifier assertions do not
            cover it.
          '';
        };

        consumers = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "app.service" ];
          description = ''
            Units that need this credential. The reconciler is ordered `before`
            each of them and (unless `bindConsumers = false`) is pulled in as a
            `Requires=` dependency, so a consumer cannot start against a role
            whose password was never applied.
          '';
        };

        bindConsumers = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Make `consumers` `Requires=` this reconciler (fail closed). Set false
            for ordering-only (`After=`), which lets a consumer start even when
            the reconcile failed.
          '';
        };

        afterRoles = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "app" ];
          description = ''
            Other roles in this module that must be reconciled first. Needed when
            `defaultPrivilegesFrom` names a role this module also creates.
          '';
        };

        extraAfterUnits = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "tailscaled.service" ];
          description = "Extra units to order after (a VPN, a leader proxy, ...).";
        };

        restartTriggers = mkOption {
          type = types.listOf types.unspecified;
          default = [ ];
          example = lib.literalExpression ''
            [ config.age.secrets.db-password-app.file ]
          '';
          description = ''
            Values that, when they change, re-run this reconciler on the next
            `nixos-rebuild switch`. Point this at the *encrypted source* of the
            secret (agenix `.file`, sops source file) — NOT at the runtime path
            (`.path`, `/run/secrets/...`), which is a constant and therefore never
            triggers anything on rotation.
          '';
        };

        description = mkOption {
          type = types.str;
          default = "Reconcile PostgreSQL role ${name} on an external server";
          defaultText = lib.literalExpression ''"Reconcile PostgreSQL role <name> on an external server"'';
          description = "systemd unit description.";
        };
      };
    }
  );

  allIdents = lib.flatten (
    mapAttrsToList (
      name: role:
      [ name ]
      ++ role.ownsDatabases
      ++ role.revokePublicConnect
      ++ lib.concatMap (
        ro:
        [ ro.database ]
        ++ ro.schemas
        ++ lib.optional (ro.defaultPrivilegesFrom != null) ro.defaultPrivilegesFrom
      ) role.readOnly
    ) cfg.roles
  );
in
{
  options.services.postgresql-external-roles = {
    enable = lib.mkEnableOption "reconciling roles, passwords and grants into an external PostgreSQL server";

    package = lib.mkPackageOption pkgs "postgresql" { };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "db.internal.example.com";
      description = ''
        Host of the PostgreSQL server to reconcile. Loopback is a normal value
        here: the server may be reached through a local leader proxy or an SSH
        tunnel and still not be managed by this host.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 5432;
      description = "Port of the PostgreSQL server.";
    };

    superuser = mkOption {
      type = types.str;
      default = "postgres";
      description = "Role used to connect. Needs CREATEROLE plus membership in the roles it grants for.";
    };

    superuserPasswordFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/pg-superuser-password";
      description = ''
        File holding the connecting role's password, loaded via
        `LoadCredential` and exported as `PGPASSWORD` (never argv). Null for
        peer/ident/trust or certificate authentication.
      '';
    };

    maintenanceDatabase = mkOption {
      type = types.str;
      default = "postgres";
      description = "Database used for cluster-wide statements (role and database-level DDL).";
    };

    sslMode = mkOption {
      type = types.enum [
        "disable"
        "allow"
        "prefer"
        "require"
        "verify-ca"
        "verify-full"
      ];
      default = "prefer";
      example = "verify-full";
      description = ''
        `PGSSLMODE` for the reconcile connection. The default matches libpq's,
        which silently accepts cleartext if the server does not offer TLS — set
        `require` or higher when the server is off-box.
      '';
    };

    connectTimeoutSec = mkOption {
      type = types.int;
      default = 10;
      description = "`PGCONNECT_TIMEOUT` for each psql invocation.";
    };

    readyTimeoutSec = mkOption {
      type = types.int;
      default = 120;
      description = "How long to poll `pg_isready` before failing the unit.";
    };

    suppressStatementLogging = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Issue `SET log_statement = 'none'` before the `ALTER ROLE ... PASSWORD`,
        so the cleartext does not land in the server log on a cluster that logs
        DDL. Requires a superuser connection; set false when reconciling with a
        merely-CREATEROLE role, otherwise the SET aborts the unit.
      '';
    };

    dynamicUser = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Run each reconciler as a `DynamicUser`. Safe because every secret arrives
        through `LoadCredential` and nothing is persisted. Set false (and use
        `user`) when the connection relies on peer/ident authentication, which
        maps the *unix* user name to a database role.
      '';
    };

    user = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "postgres";
      description = "User to run as when `dynamicUser = false`.";
    };

    restartSec = mkOption {
      type = types.int;
      default = 30;
      description = "`RestartSec` for the `Restart=on-failure` retry loop.";
    };

    roles = mkOption {
      type = types.attrsOf roleOpts;
      default = { };
      description = "Roles to reconcile, keyed by role name.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.versionAtLeast cfg.package.version "14";
        message = ''
          services.postgresql-external-roles: the psql from `package` must be
          >= 14; passwords are passed through psql's `\getenv`, added in
          PostgreSQL 14, to keep the cleartext off the process command line.
          Got ${cfg.package.version}.
        '';
      }
      {
        assertion = cfg.dynamicUser || cfg.user != null;
        message = "services.postgresql-external-roles: set `user` when `dynamicUser = false`.";
      }
      {
        assertion = !(builtins.any badIdent allIdents);
        message = ''
          services.postgresql-external-roles: these names are interpolated into
          SQL identifiers and must match ${identPattern}:
          ${concatStringsSep ", " (builtins.filter badIdent allIdents)}
        '';
      }
    ];

    systemd.services = lib.mapAttrs' (
      name: role:
      lib.nameValuePair "pg-role-${name}" {
        inherit (role) description restartTriggers;
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [
          "network-online.target"
        ]
        ++ role.extraAfterUnits
        ++ map (r: "pg-role-${r}.service") role.afterRoles;
        before = role.consumers;
        requiredBy = lib.optionals role.bindConsumers role.consumers;
        script = roleScript name role;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # A oneshot may use Restart=on-failure (not =always). An unreachable
          # server is a transient condition on a host that boots before its VPN.
          Restart = "on-failure";
          RestartSec = cfg.restartSec;
          DynamicUser = cfg.dynamicUser;
          User = mkIf (!cfg.dynamicUser) cfg.user;
          LoadCredential =
            lib.optional (cfg.superuserPasswordFile != null) "superuser:${toString cfg.superuserPasswordFile}"
            ++ lib.optional (role.passwordFile != null) "password:${toString role.passwordFile}";
          CapabilityBoundingSet = "";
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHome = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectSystem = "strict";
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = [
            "@system-service"
            "~@privileged"
          ];
        };
      }
    ) cfg.roles;
  };
}
