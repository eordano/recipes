{
  pkgs,
  lib,
  config,
  options,
  ...
}:
let
  cfg = config.modules.services.postgresql;
  inherit (lib)
    types
    mkOption
    mkEnableOption
    mkIf
    mkForce
    mkDefault
    concatStringsSep
    mapAttrsToList
    ;

  # `lib.mkDefault` is `mkOverride 1000`; anything the operator sets themselves
  # lands at 100. A package still sitting at 1000 is upstream's
  # stateVersion-derived default, not a deliberate pin.
  mkDefaultPriority = 1000;

  # Render one pg_hba.conf line from a typed rule. 'local' rules omit the
  # address column; everything else requires it (enforced by assertion below).
  formatAuthRule =
    _: rule:
    let
      database =
        if builtins.isList rule.database then concatStringsSep "," rule.database else rule.database;
      user = if builtins.isList rule.user then concatStringsSep "," rule.user else rule.user;
      authOptions =
        if rule.options != { } then
          concatStringsSep " " (mapAttrsToList (k: v: "${k}=${v}") rule.options)
        else
          "";
      fields =
        if rule.type == "local" then
          [
            rule.type
            database
            user
            rule.method
            authOptions
          ]
        else
          [
            rule.type
            database
            user
            rule.address
            rule.method
            authOptions
          ];
    in
    concatStringsSep " " (builtins.filter (x: x != "") fields);

  formatIdentMap =
    mapName: rules:
    concatStringsSep "\n" (
      mapAttrsToList (systemUser: pgUser: "${mapName} ${systemUser} ${pgUser}") rules
    );

  # Default pg_hba rules. Names are prefixed with a numeric sort key because the
  # final file is emitted in sorted-name order (first match wins in pg_hba, so
  # order is load-bearing). These let a local `root` reach the `postgres`
  # superuser via peer auth + the superuser_map ident mapping. Override any of
  # them by name, or set the entry to `null` to drop it entirely.
  defaultAuthRules = {
    "45-local-root-as-postgres" = {
      type = "local";
      database = "all";
      user = "postgres";
      method = "peer";
      options = {
        map = "superuser_map";
      };
    };
    "50-local-root" = {
      type = "local";
      database = "all";
      user = "root";
      method = "peer";
      options = {
        map = "superuser_map";
      };
    };
    "50-local-postgres" = {
      type = "local";
      database = "all";
      user = "postgres";
      method = "peer";
      options = { };
    };
  };

  defaultIdentMap = {
    superuser_map = {
      "root" = "postgres";
      "postgres" = "postgres";
      "/^(.*)$" = "\\1";
    };
  };
in
{
  options.modules.services.postgresql = {
    enable = mkEnableOption "postgresql server";

    requirePinnedPackage = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Fail evaluation unless `services.postgresql.package` is set explicitly.
        Upstream defaults that option from `system.stateVersion`, so leaving it
        alone means a major-version change can arrive as a side effect of
        bumping `stateVersion`. Off by default so the module stays drop-in.
      '';
    };

    extensions = mkOption {
      type = types.functionTo (types.listOf types.package);
      default =
        ps: with ps; [
          pgvector
        ];
      description = "PostgreSQL extensions as a function receiving the extension package set";
      example = lib.literalExpression "ps: with ps; [ postgis pgvector ]";
    };

    enableExporter = mkEnableOption "PostgreSQL Prometheus exporter";

    exporterPort = mkOption {
      type = types.int;
      default = 9187;
      description = "Port for PostgreSQL Prometheus exporter";
    };

    exporterListenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        Interface the PostgreSQL Prometheus exporter binds to. Defaults to
        loopback so the metrics endpoint (which is unauthenticated and exposes
        detailed DB internals) is not reachable off-box. Set to "0.0.0.0" only
        behind a firewall/auth layer.
      '';
    };

    exporterDataSourceName = mkOption {
      type = types.str;
      default = "user=postgres database=postgres host=/run/postgresql sslmode=disable";
      description = "PostgreSQL connection string for the exporter";
    };

    authRules = mkOption {
      type = types.attrsOf (
        types.nullOr (
          types.submodule {
            options = {
              type = mkOption {
                type = types.enum [
                  "local"
                  "host"
                  "hostssl"
                  "hostnossl"
                  "hostgssenc"
                  "hostnogssenc"
                ];
                description = "Connection type";
              };
              database = mkOption {
                type = types.either types.str (types.listOf types.str);
                description = "Database name(s), 'all', 'sameuser', 'samerole', or regex";
              };
              user = mkOption {
                type = types.either types.str (types.listOf types.str);
                description = "User name(s), 'all', or regex";
              };
              address = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Client address (not used for 'local' type)";
              };
              method = mkOption {
                type = types.enum [
                  "trust"
                  "reject"
                  "scram-sha-256"
                  "md5"
                  "password"
                  "gss"
                  "sspi"
                  "ident"
                  "peer"
                  "ldap"
                  "radius"
                  "cert"
                  "pam"
                  "bsd"
                ];
                description = "Authentication method";
              };
              options = mkOption {
                type = types.attrsOf types.str;
                default = { };
                description = "Auth method options (e.g., map=mymap)";
              };
            };
          }
        )
      );
      default = { };
      description = "PostgreSQL authentication rules. Set a rule to null to remove it.";
    };

    identMap = mkOption {
      type = types.attrsOf (types.attrsOf types.str);
      default = { };
      description = "Identity mapping rules";
      example = {
        superuser_map = {
          "postgres" = "postgres";
          "/^(.*)$" = "\\1";
        };
      };
    };

    setupStatements = {
      initial = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "SQL statements to run during initial database setup (before users/databases)";
        example = [ "CREATE EXTENSION IF NOT EXISTS pgcrypto" ];
      };

      postInit = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "SQL statements to run after users and databases are created";
        example = [ "GRANT CREATE ON SCHEMA public TO myuser" ];
      };

      perDatabase = mkOption {
        type = types.attrsOf (types.listOf types.str);
        default = { };
        description = "SQL statements to run per database after creation";
        example = {
          mydb = [
            "CREATE EXTENSION postgis"
            "GRANT ALL ON SCHEMA public TO myuser"
          ];
        };
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion =
          !cfg.requirePinnedPackage
          || options.services.postgresql.package.highestPrio < mkDefaultPriority;
        message = ''
          modules.services.postgresql.requirePinnedPackage is set, but
          services.postgresql.package is still at its upstream default, which is
          derived from system.stateVersion. Pin it explicitly
          (e.g. services.postgresql.package = pkgs.postgresql_17;) so a major
          version change is a deliberate act.
        '';
      }
    ]
    ++ lib.flatten (
      mapAttrsToList (name: rule: [
        {
          assertion = rule.type != "local" || rule.address == null;
          message = "PostgreSQL auth rule '${name}': 'local' connection type cannot have an address field";
        }
        {
          assertion = rule.type == "local" || rule.address != null;
          message = "PostgreSQL auth rule '${name}': non-local connection types (${rule.type}) require an address field";
        }
      ]) (lib.filterAttrs (_: v: v != null) cfg.authRules)
    )
    ++ [
      {
        assertion =
          let
            hasHostRules = lib.any (rule: rule != null && rule.type != "local") (lib.attrValues cfg.authRules);
          in
          !hasHostRules || config.services.postgresql.enableTCPIP;
        message = "PostgreSQL has host-based authentication rules but enableTCPIP is not set to true. Host rules require TCP/IP connections to be enabled.";
      }
    ];

    services.postgresql = {
      enable = mkDefault true;
      # Any host-based rule implies we must listen on TCP/IP, so flip it on
      # automatically (the assertion above is the belt-and-braces backstop).
      enableTCPIP = mkDefault (
        lib.any (rule: rule != null && rule.type != "local") (lib.attrValues cfg.authRules)
      );
      extensions = cfg.extensions;

      authentication =
        let
          activeRules = lib.filterAttrs (_: rule: rule != null) (defaultAuthRules // cfg.authRules);
          sortedRules = lib.sort (a: b: a.name < b.name) (
            mapAttrsToList (name: rule: { inherit name rule; }) activeRules
          );
          formattedRules = map (x: formatAuthRule x.name x.rule) sortedRules;
        in
        mkForce (concatStringsSep "\n" formattedRules);

      identMap = mkForce (
        concatStringsSep "\n" (mapAttrsToList formatIdentMap (defaultIdentMap // cfg.identMap))
      );

      initialScript = mkIf (cfg.setupStatements.initial != [ ]) (
        pkgs.writeText "postgresql-initial.sql" (concatStringsSep "\n" cfg.setupStatements.initial)
      );
    };

    # Post-init SQL runs from a oneshot ordered AFTER postgresql-setup but
    # BEFORE postgresql.target. Anything that waits on postgresql.target (via
    # `after = [ "postgresql.target" ]`) therefore sees a fully provisioned
    # database — extensions created, grants applied — instead of racing the
    # server's bare readiness. This is the fix for the classic race where a
    # consumer starts before its extensions/grants exist.
    systemd.services.postgresql-custom-setup =
      let
        postgresqlPkg = config.services.postgresql.package;
        socketDir =
          if config.services.postgresql.settings ? unix_socket_directories then
            builtins.head (lib.splitString "," config.services.postgresql.settings.unix_socket_directories)
          else
            "/run/postgresql";
        port =
          if config.services.postgresql.settings ? port then
            config.services.postgresql.settings.port
          else
            5432;
      in
      mkIf (cfg.setupStatements.postInit != [ ] || cfg.setupStatements.perDatabase != { }) {
        description = "Custom PostgreSQL setup statements";
        after = [ "postgresql-setup.service" ];
        requires = [ "postgresql-setup.service" ];
        before = [ "postgresql.target" ];
        requiredBy = [ "postgresql.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "postgres";
          Group = "postgres";
        };
        script = ''
          PSQL="${postgresqlPkg}/bin/psql -U postgres --port=${toString port} -h ${socketDir}"

          ${lib.optionalString (cfg.setupStatements.postInit != [ ]) ''
            echo "Running post-initialization statements..."
            ${lib.concatMapStringsSep "\n" (stmt: ''
              $PSQL <<'EOSQL'
              ${stmt}
              EOSQL
            '') cfg.setupStatements.postInit}
          ''}

          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (db: stmts: ''
              echo "Running setup statements for database ${db}..."
              ${lib.concatMapStringsSep "\n" (stmt: ''
                $PSQL -d "${db}" <<'EOSQL'
                ${stmt}
                EOSQL
              '') stmts}
            '') cfg.setupStatements.perDatabase
          )}
        '';
      };

    services.prometheus.exporters.postgres = mkIf cfg.enableExporter {
      enable = true;
      port = cfg.exporterPort;
      listenAddress = cfg.exporterListenAddress;
      dataSourceName = cfg.exporterDataSourceName;
      runAsLocalSuperUser = true;
      extraFlags = [
        "--collector.database"
        "--collector.locks"
        "--collector.replication"
        "--collector.stat_bgwriter"
        "--collector.stat_database"
        "--collector.stat_user_tables"
        "--collector.stat_wal_receiver"
      ];
    };
  };
}
