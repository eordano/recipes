{
  pkgs,
  lib ? pkgs.lib,
}:

let
  inherit (lib)
    escapeShellArg
    optionalString
    ;

  mkMigrate =
    {
      name ? "pg-migrate",
      migrations,
      database,
      ledgerTable ? "public.schema_migrations",
      host ? "/run/postgresql",
      port ? null,
      psql ? pkgs.postgresql,
      extraArgs ? [ ],
    }:
    let
      portArg = optionalString (port != null) " -p ${toString port}";
      extra = optionalString (extraArgs != [ ]) (" " + lib.escapeShellArgs extraArgs);
    in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        psql
        pkgs.coreutils
      ];
      text = ''
        # The glob below expands in sorted (lexicographic) order, which is the
        # whole reason the files are named NNNN-*. nullglob so an empty or
        # absent migrations directory is a clean no-op, not a `basename` crash.
        shopt -s nullglob

        PSQL="${psql}/bin/psql -v ON_ERROR_STOP=1 -h ${escapeShellArg host}${portArg} -d ${escapeShellArg database}${extra}"

        # Per-file ledger. Do NOT collapse this into a single sentinel row: a
        # "0001 applied" guard makes every migration added later look already
        # applied on any database that has ever run 0001.
        $PSQL -c "CREATE TABLE IF NOT EXISTS ${ledgerTable} (
            filename   text PRIMARY KEY,
            applied_at timestamptz NOT NULL DEFAULT now()
        );"

        for f in ${migrations}/*.sql; do
          name=$(basename "$f")

          # psql expands :'name' only for file/stdin input, never for -c, so the
          # existence probe is fed on stdin (`-f -`) with psql's own safe
          # quoting rather than string-built into the SQL.
          applied=$(echo "select exists(select 1 from ${ledgerTable} where filename = :'name');" \
            | $PSQL -v name="$name" -tAf -)
          if [ "$applied" = t ]; then
            echo "skipping $name (already applied)"
            continue
          fi

          echo "applying $name"
          # The file and its ledger INSERT run as ONE transaction: -f "$f" then
          # -f - (the INSERT on stdin) under --single-transaction. If the file
          # fails half-way, the whole thing rolls back and the ledger stays
          # empty for this name, so the next run retries it from scratch.
          echo "INSERT INTO ${ledgerTable} (filename) VALUES (:'name');" \
            | $PSQL -v name="$name" --single-transaction -f "$f" -f -
        done
      '';
    };

  mkMigrateService =
    args@{
      name ? "pg-migrate",
      user ? null,
      group ? null,
      ...
    }:
    let
      migrate = mkMigrate (
        removeAttrs args [
          "user"
          "group"
          "serviceConfig"
        ]
      );
    in
    {
      description = "Apply ${name} PostgreSQL migrations (idempotent, per-file ledger)";
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${migrate}/bin/${name}";
      }
      // lib.optionalAttrs (user != null) { User = user; }
      // lib.optionalAttrs (group != null) { Group = group; }
      // (args.serviceConfig or { });
    };
in
{
  inherit
    mkMigrate
    mkMigrateService
    ;
}
