{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.services.postgresql-major-upgrade;

  inherit (lib)
    mkIf
    mkOption
    mkEnableOption
    types
    ;

  newPkg = cfg.newPackage;
  newMajor = newPkg.psqlSchema;

  # nixpkgs keeps throwing stubs for majors that reached EOL (postgresql_13 and
  # friends), so every candidate has to survive tryEval before we touch it.
  usableOldPackage =
    v:
    let
      probe = builtins.tryEval (lib.isDerivation v && v ? psqlSchema && builtins.isString v.psqlSchema);
    in
    probe.success && probe.value;

  # Only the canonical postgresql_<major> attrs: the variants (…_jit and the
  # unversioned alias) repeat a psqlSchema already covered, which would emit
  # duplicate case branches.
  availableOld = lib.filterAttrs (
    n: v: builtins.match "postgresql_[0-9]+" n != null && usableOldPackage v
  ) pkgs;

  oldPackageByMajor = lib.listToAttrs (
    lib.mapAttrsToList (_: v: lib.nameValuePair v.psqlSchema v) availableOld
  );

  oldPackageCases = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (major: v: "        ${major}) oldpkg=${v};;") oldPackageByMajor
  );

  socketDir = "/run/postgresql-major-upgrade";

  upgradeScript = pkgs.writeShellApplication {
    name = "postgresql-major-upgrade";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gnused
      gnugrep
      util-linux
      gzip
    ];
    text = ''
      set -euo pipefail

      DATA_DIR=${lib.escapeShellArg cfg.dataDir}
      BACKUP_DIR=${lib.escapeShellArg cfg.backupDir}
      NEWPKG=${newPkg}
      NEW_MAJOR=${newMajor}
      SOCKET_DIR=${socketDir}
      PGUSER_NAME=${lib.escapeShellArg cfg.postgresUser}

      log() { echo "pg-upgrade: $*"; }
      die() { echo "pg-upgrade: FATAL: $*" >&2; exit 1; }

      # as_pg runs a command as the postgres user. The upgrade never runs the
      # server as root, and never opens a TCP socket.
      as_pg() { runuser -u "$PGUSER_NAME" -- "$@"; }

      if [ ! -e "$DATA_DIR/PG_VERSION" ]; then
        log "no cluster at $DATA_DIR (PG_VERSION absent) — nothing to upgrade"
        exit 0
      fi

      OLD_MAJOR=$(tr -d '[:space:]' < "$DATA_DIR/PG_VERSION")
      if [ "$OLD_MAJOR" = "$NEW_MAJOR" ]; then
        log "cluster already at major $NEW_MAJOR — nothing to do"
        exit 0
      fi

      log "detected major upgrade: $OLD_MAJOR -> $NEW_MAJOR"

      if [ "$OLD_MAJOR" -gt "$NEW_MAJOR" ]; then
        die "cluster is NEWER ($OLD_MAJOR) than the configured package ($NEW_MAJOR); refusing to downgrade"
      fi

      oldpkg=""
      ${
        if cfg.oldPackage != null then
          ''
            oldpkg=${cfg.oldPackage}
            if [ "${cfg.oldPackage.psqlSchema}" != "$OLD_MAJOR" ]; then
              die "oldPackage is major ${cfg.oldPackage.psqlSchema} but the cluster is $OLD_MAJOR"
            fi
          ''
        else
          ''
            case "$OLD_MAJOR" in
            ${oldPackageCases}
              *) die "no postgresql package available for major $OLD_MAJOR" ;;
            esac
          ''
      }
      [ -n "$oldpkg" ] || die "no postgresql package available for major $OLD_MAJOR"
      log "old binaries: $oldpkg"

      STAMP="$DATA_DIR/.major-upgrade-to-$NEW_MAJOR.done"
      if [ -e "$STAMP" ]; then
        die "stamp $STAMP exists but PG_VERSION says $OLD_MAJOR — inconsistent state, refusing"
      fi

      install -d -m 0700 -o "$PGUSER_NAME" -g "$PGUSER_NAME" "$BACKUP_DIR"
      install -d -m 0755 -o "$PGUSER_NAME" -g "$PGUSER_NAME" "$SOCKET_DIR"

      # ---- preflight: space ---------------------------------------------------
      # Everything here avoids `producer | consumer-that-exits-early`: under
      # pipefail the early exit shows up as a SIGPIPE failure in the producer.
      DATA_KB=$(du -sk "$DATA_DIR" | cut -f1)
      DF_OUT=$(df -Pk "$BACKUP_DIR")
      FREE_KB=$(awk 'NR==2 {print $4}' <<<"$DF_OUT")
      NEED_KB=$(( DATA_KB * ${toString cfg.requiredFreeSpacePercent} / 100 ))
      log "data ''${DATA_KB}KB, free ''${FREE_KB}KB, need ~''${NEED_KB}KB for the dump"
      if [ "$FREE_KB" -lt "$NEED_KB" ]; then
        die "insufficient free space for the backup (need ''${NEED_KB}KB, have ''${FREE_KB}KB)"
      fi

      TS=$(date -u +%Y%m%dT%H%M%SZ)
      DUMP="$BACKUP_DIR/dumpall-$OLD_MAJOR-to-$NEW_MAJOR-$TS.sql"
      MANIFEST="$BACKUP_DIR/manifest-$TS.txt"

      # ---- step 1/7: start the OLD server with connectivity disabled ----------
      # listen_addresses=''' means no TCP at all; clients cannot reach it while we
      # work. unix_socket_directories points at a private dir, so even local
      # peers using the default socket path will not find this instance.
      start_server() {
        local pkg="$1" dir="$2"
        as_pg "$pkg/bin/pg_ctl" -D "$dir" -w -t ${toString cfg.startTimeoutSeconds} \
          -o "-c listen_addresses=''' -c unix_socket_directories=$SOCKET_DIR -c unix_socket_permissions=0700" \
          -l "$BACKUP_DIR/pg_ctl-$TS.log" start
      }
      stop_server() {
        local pkg="$1" dir="$2"
        as_pg "$pkg/bin/pg_ctl" -D "$dir" -w -t ${toString cfg.stopTimeoutSeconds} -m fast stop
      }

      log "step 1/7: starting OLD server (no TCP, private socket)"
      start_server "$oldpkg" "$DATA_DIR" || die "could not start the old cluster"

      cleanup_old() {
        if as_pg "$oldpkg/bin/pg_ctl" -D "$DATA_DIR" status >/dev/null 2>&1; then
          stop_server "$oldpkg" "$DATA_DIR" || true
        fi
      }
      trap cleanup_old EXIT

      psql_old() { as_pg "$oldpkg/bin/psql" -h "$SOCKET_DIR" -U "$PGUSER_NAME" -X -A -t "$@"; }

      # Capture the cluster's identity BEFORE dumping: initdb for the new cluster
      # must reproduce the same encoding and locale, or the restore will differ
      # subtly from the original (or fail outright on collation-sensitive data).
      ENCODING=$(psql_old -d postgres -c "SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname='template1'")
      LC_COLLATE_OLD=$(psql_old -d postgres -c "SELECT datcollate FROM pg_database WHERE datname='template1'")
      LC_CTYPE_OLD=$(psql_old -d postgres -c "SELECT datctype FROM pg_database WHERE datname='template1'")
      log "old cluster: encoding=$ENCODING collate=$LC_COLLATE_OLD ctype=$LC_CTYPE_OLD"

      # Manifest: what we expect to still be there afterwards.
      {
        echo "# databases"
        psql_old -d postgres -c "SELECT datname FROM pg_database WHERE datallowconn ORDER BY 1"
        echo "# extensions"
        for db in $(psql_old -d postgres -c "SELECT datname FROM pg_database WHERE datallowconn ORDER BY 1"); do
          for ext in $(psql_old -d "$db" -c "SELECT extname FROM pg_extension ORDER BY 1"); do
            echo "$db:$ext"
          done
        done
        echo "# relcounts"
        for db in $(psql_old -d postgres -c "SELECT datname FROM pg_database WHERE datallowconn ORDER BY 1"); do
          n=$(psql_old -d "$db" -c "SELECT count(*) FROM pg_class WHERE relkind IN ('r','p','m','S')")
          echo "$db:$n"
        done
      } > "$MANIFEST"
      log "manifest written to $MANIFEST"

      # ---- step 2/7: back up all data ----------------------------------------
      # The NEW pg_dumpall reads an OLD server: that direction is supported and
      # is what upstream recommends for cross-version dumps.
      # No --clean: the restore target is always a cluster we just initdb'd, so
      # there is nothing to drop, and --clean emits DROP ROLE for the very role
      # the restore connects as ("current user cannot be dropped").
      log "step 2/7: dumping all data with the new pg_dumpall"
      as_pg "$NEWPKG/bin/pg_dumpall" -h "$SOCKET_DIR" -U "$PGUSER_NAME" > "$DUMP"
      DUMP_TAIL=$(tail -c 2000 "$DUMP")
      if ! grep -q 'PostgreSQL database cluster dump complete' <<<"$DUMP_TAIL"; then
        die "dump did not end with a completion marker — refusing to continue ($DUMP)"
      fi
      DUMP_KB=$(du -sk "$DUMP" | cut -f1)
      log "dump ok: $DUMP (''${DUMP_KB}KB)"

      # ---- step 3/7: take the old version down --------------------------------
      log "step 3/7: stopping the OLD server"
      stop_server "$oldpkg" "$DATA_DIR" || die "old cluster would not stop cleanly"
      trap - EXIT

      OLD_DIR="$DATA_DIR.major-$OLD_MAJOR-$TS"
      log "preserving old data directory at $OLD_DIR"
      mv "$DATA_DIR" "$OLD_DIR"

      # ---- step 4/7: bring the new version up, still without connectivity -----
      log "step 4/7: initdb + starting the NEW server (no TCP, private socket)"
      install -d -m 0700 -o "$PGUSER_NAME" -g "$PGUSER_NAME" "$DATA_DIR"
      as_pg "$NEWPKG/bin/initdb" -D "$DATA_DIR" \
        -E "$ENCODING" --lc-collate="$LC_COLLATE_OLD" --lc-ctype="$LC_CTYPE_OLD" \
        >> "$BACKUP_DIR/initdb-$TS.log" 2>&1 || die "initdb failed"

      start_server "$NEWPKG" "$DATA_DIR" || die "could not start the new cluster"

      cleanup_new() {
        if as_pg "$NEWPKG/bin/pg_ctl" -D "$DATA_DIR" status >/dev/null 2>&1; then
          stop_server "$NEWPKG" "$DATA_DIR" || true
        fi
      }
      trap cleanup_new EXIT

      psql_new() { as_pg "$NEWPKG/bin/psql" -h "$SOCKET_DIR" -U "$PGUSER_NAME" -X -A -t "$@"; }

      # Every extension the old cluster used must exist in the new package, or the
      # restore will fail partway through. Checking up front turns a half-restored
      # cluster into a clean, actionable abort. This is the failure you get when a
      # package is swapped for a bare one without its extension set.
      MISSING=""
      while IFS=: read -r db ext; do
        [ -n "''${ext:-}" ] || continue
        have=$(psql_new -d postgres -c "SELECT count(*) FROM pg_available_extensions WHERE name='$ext'")
        if [ "''${have//[[:space:]]/}" = "0" ]; then
          MISSING="$MISSING $db:$ext"
        fi
      done < <(sed -n '/^# extensions/,/^# relcounts/p' "$MANIFEST" | grep -E '^[^#]+:[^:]+$' || true)
      if [ -n "$MISSING" ]; then
        die "the new package is missing extensions used by the old cluster:$MISSING"
      fi

      # ---- step 5/7: restore locally ------------------------------------------
      log "step 5/7: restoring the dump into the new cluster"
      # initdb already created the bootstrap superuser, but pg_dumpall always
      # emits CREATE ROLE for it, which aborts the restore under ON_ERROR_STOP.
      # Drop that one statement into a separate file so the archived dump stays
      # byte-for-byte what the old cluster produced. The following ALTER ROLE
      # still re-applies the role's attributes.
      RESTORE_SQL="$BACKUP_DIR/restore-input-$TS.sql"
      sed "/^CREATE ROLE $PGUSER_NAME;[[:space:]]*$/d" "$DUMP" > "$RESTORE_SQL"
      chown "$PGUSER_NAME" "$RESTORE_SQL"

      if ! as_pg "$NEWPKG/bin/psql" -h "$SOCKET_DIR" -U "$PGUSER_NAME" -X \
            -v ON_ERROR_STOP=1 -d postgres -f "$RESTORE_SQL" >> "$BACKUP_DIR/restore-$TS.log" 2>&1; then
        echo "pg-upgrade: last lines of the restore log:" >&2
        tail -n 20 "$BACKUP_DIR/restore-$TS.log" >&2 || true
        die "restore failed — old data is intact at $OLD_DIR, see $BACKUP_DIR/restore-$TS.log"
      fi

      # ---- step 6/7: collation refresh + reindex ------------------------------
      # A dump/restore rebuilds every index from scratch, so text ordering already
      # matches the new glibc. What can still be stale is the collation VERSION
      # postgres recorded per database/collation; refreshing it stops the
      # "collation version mismatch" warnings and the spurious reindex advice.
      log "step 6/7: refreshing collation versions"
      for db in $(psql_new -d postgres -c "SELECT datname FROM pg_database WHERE datallowconn ORDER BY 1"); do
        psql_new -d "$db" -c "ALTER DATABASE \"$db\" REFRESH COLLATION VERSION" >/dev/null || true
        psql_new -d "$db" -c "ALTER COLLATION pg_catalog.\"default\" REFRESH VERSION" >/dev/null 2>&1 || true
      done
    ''
    + lib.optionalString cfg.reindex ''
      log "step 6/7: reindexing (reindex = true)"
      for db in $(psql_new -d postgres -c "SELECT datname FROM pg_database WHERE datallowconn ORDER BY 1"); do
        as_pg "$NEWPKG/bin/reindexdb" -h "$SOCKET_DIR" -U "$PGUSER_NAME" -d "$db" \
          >> "$BACKUP_DIR/reindex-$TS.log" 2>&1 || die "reindexdb failed for $db"
      done
    ''
    + ''

      # ---- step 7/7: health / sanity / vacuum ---------------------------------
      log "step 7/7: sanity checks"
      FAIL=""
      while IFS=: read -r db n; do
        [ -n "''${n:-}" ] || continue
        got=$(psql_new -d "$db" -c "SELECT count(*) FROM pg_class WHERE relkind IN ('r','p','m','S')" || echo missing)
        if [ "$got" != "$n" ]; then
          FAIL="$FAIL $db(expected $n, got $got)"
        fi
      done < <(sed -n '/^# relcounts/,$p' "$MANIFEST" | grep -E '^[^#]+:[0-9]+$' || true)
      if [ -n "$FAIL" ]; then
        die "relation counts differ after restore:$FAIL — old data is intact at $OLD_DIR"
      fi
      log "relation counts match the pre-upgrade manifest"
    ''
    + lib.optionalString cfg.vacuum ''
      log "vacuum + analyze"
      as_pg "$NEWPKG/bin/vacuumdb" -h "$SOCKET_DIR" -U "$PGUSER_NAME" --all --analyze \
        >> "$BACKUP_DIR/vacuum-$TS.log" 2>&1 || die "vacuumdb failed"
    ''
    + ''

      # ---- done: stop, and let the real unit bring it up ----------------------
      log "stopping the migration instance; postgresql.service will start $NEW_MAJOR normally"
      stop_server "$NEWPKG" "$DATA_DIR" || die "new cluster would not stop cleanly"
      trap - EXIT

      touch "$STAMP"
      log "upgrade $OLD_MAJOR -> $NEW_MAJOR complete"
      log "  dump:     $DUMP"
      log "  old data: $OLD_DIR"
    ''
    + lib.optionalString (!cfg.keepOldDataDir) ''
      log "keepOldDataDir = false: removing $OLD_DIR"
      rm -rf "$OLD_DIR"
    '';
  };
in
{
  options.modules.services.postgresql-major-upgrade = {
    enable = mkEnableOption "automatic PostgreSQL major-version upgrade via dump/restore";

    dataDir = mkOption {
      type = types.str;
      default = config.services.postgresql.dataDir or "/var/lib/postgresql";
      defaultText = "config.services.postgresql.dataDir";
      description = ''
        Cluster directory to upgrade in place. This must be the SAME path across
        versions; the NixOS default of /var/lib/postgresql/$version is version
        specific, which sidesteps upgrades entirely by starting an empty cluster.
      '';
    };

    newPackage = mkOption {
      type = types.package;
      default = config.services.postgresql.package;
      defaultText = "config.services.postgresql.package";
      description = "Target PostgreSQL package. Must carry every extension the old cluster uses.";
    };

    oldPackage = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = ''
        Package used to run the OLD cluster while it is dumped. When null the
        major is read from PG_VERSION and the matching plain nixpkgs package is
        used.

        Set this explicitly when the old cluster uses extensions: dumping a
        column whose type comes from an extension calls that type's output
        function, so the old server has to be able to load the extension's
        shared object. A plain package cannot, and pg_dumpall fails partway.
      '';
    };

    postgresUser = mkOption {
      type = types.str;
      default = "postgres";
      description = "System user that owns the cluster.";
    };

    backupDir = mkOption {
      type = types.str;
      default = "/var/backup/postgresql-major-upgrade";
      description = "Where the pre-upgrade dump, manifest and per-step logs are written.";
    };

    keepOldDataDir = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Keep the pre-upgrade cluster directory, renamed with its major version and
        a timestamp. Leaving this on is what makes the upgrade reversible.
      '';
    };

    reindex = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Run reindexdb after the restore. A dump/restore already rebuilds indexes,
        so this is belt-and-braces against a glibc collation change; turn it off
        to save time on large clusters.
      '';
    };

    vacuum = mkOption {
      type = types.bool;
      default = true;
      description = "Run vacuumdb --all --analyze before handing over, so the new cluster starts with fresh statistics.";
    };

    requireManualStart = mkOption {
      type = types.bool;
      default = false;
      description = ''
        When false (the default) the upgrade is pulled in by postgresql.service
        and runs ahead of it, so a version bump migrates and comes back up on
        its own.

        When true the upgrade never runs by itself. postgresql.service still
        refuses to start on a cluster whose major does not match its package, so
        the database stays down and tells you to run
        `systemctl start postgresql-major-upgrade.service` yourself. Use this
        when you would rather inspect the migrated cluster before anything can
        connect to it.

        Either way postgres is guarded by its own start check rather than by a
        Requires= on this unit, so re-running the upgrade by hand never takes a
        healthy database offline.
      '';
    };

    requiredFreeSpacePercent = mkOption {
      type = types.int;
      default = 120;
      description = "Refuse to start unless backupDir has at least this percentage of the cluster size free.";
    };

    startTimeoutSeconds = mkOption {
      type = types.int;
      default = 120;
      description = "pg_ctl start timeout for the temporary instances.";
    };

    stopTimeoutSeconds = mkOption {
      type = types.int;
      default = 300;
      description = "pg_ctl stop timeout for the temporary instances.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.dataDir != "";
        message = "modules.services.postgresql-major-upgrade.dataDir must be set";
      }
    ];

    # The guard, not a unit dependency, is what keeps postgres off a mismatched
    # cluster. It holds even if this unit is masked, disabled or never ran, and
    # because it is only Wants= below, re-running the upgrade by hand cannot
    # drag a healthy database down with it.
    systemd.services.postgresql.preStart = lib.mkBefore ''
      if [ -e ${lib.escapeShellArg cfg.dataDir}/PG_VERSION ]; then
        on_disk=$(tr -d '[:space:]' < ${lib.escapeShellArg cfg.dataDir}/PG_VERSION)
        if [ "$on_disk" != "${newMajor}" ]; then
          echo "postgresql: cluster at ${cfg.dataDir} is major $on_disk but this package is ${newMajor}." >&2
          echo "postgresql: refusing to start on a mismatched cluster; data is NOT lost." >&2
          echo "postgresql: run: systemctl start postgresql-major-upgrade.service" >&2
          exit 1
        fi
      fi
    '';

    systemd.services.postgresql-major-upgrade = {
      description = "PostgreSQL major-version upgrade (dump/restore)";

      # Wants=, never Requires=: postgresql pulls the upgrade in and waits for
      # it, but stopping or restarting the upgrade does not propagate a stop
      # back to a running database.
      before = [ "postgresql.service" ];
      wantedBy = lib.optionals (!cfg.requireManualStart) [ "postgresql.service" ];
      after = [
        "network.target"
        "local-fs.target"
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe upgradeScript;
        TimeoutStartSec = "infinity";

        StateDirectory = "postgresql-major-upgrade";
        RuntimeDirectory = "postgresql-major-upgrade";
        RuntimeDirectoryMode = "0755";

        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          cfg.dataDir
          (builtins.dirOf cfg.dataDir)
          cfg.backupDir
          socketDir
        ];
        NoNewPrivileges = false;
        RestrictAddressFamilies = [
          "AF_UNIX"
        ];
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.backupDir} 0700 ${cfg.postgresUser} ${cfg.postgresUser} -"
    ];
  };
}
