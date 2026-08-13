{ pkgs, ... }:
let
  oldPkg = pkgs.postgresql_17.withPackages (p: [ p.pgvector ]);
  newPkg = pkgs.postgresql_18.withPackages (p: [ p.pgvector ]);

  dataDir = "/var/lib/pgcluster";
  backupDir = "/var/backup/postgresql-major-upgrade";

  rows = 500;
in
pkgs.testers.runNixOSTest {
  name = "postgresql-major-upgrade";

  nodes.machine =
    { config, ... }:
    {
      imports = [ ./default.nix ];

      i18n.supportedLocales = [
        "C.UTF-8/UTF-8"
        "en_US.UTF-8/UTF-8"
      ];

      virtualisation.diskSize = 4096;

      services.postgresql = {
        enable = true;
        package = newPkg;
        inherit dataDir;
      };

      modules.services.postgresql-major-upgrade = {
        enable = true;
        inherit dataDir;
        newPackage = newPkg;
        oldPackage = oldPkg;
        inherit backupDir;
      };

      systemd.services.seed-old-cluster = {
        description = "seed a ${oldPkg.psqlSchema} cluster to be upgraded";
        wantedBy = [ "multi-user.target" ];
        before = [ "postgresql-major-upgrade.service" ];
        requiredBy = [ "postgresql-major-upgrade.service" ];
        after = [ "local-fs.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [ pkgs.util-linux ];
        script = ''
          set -euo pipefail
          if [ -e ${dataDir}/PG_VERSION ]; then
            echo "cluster already present"; exit 0
          fi
          install -d -m 0700 -o postgres -g postgres ${dataDir}
          install -d -m 0755 -o postgres -g postgres /run/pgseed

          runuser -u postgres -- ${oldPkg}/bin/initdb -D ${dataDir} -E UTF8 \
            --lc-collate=en_US.UTF-8 --lc-ctype=en_US.UTF-8
          runuser -u postgres -- ${oldPkg}/bin/pg_ctl -D ${dataDir} -w -t 120 \
            -o "-c listen_addresses=''' -c unix_socket_directories=/run/pgseed" \
            -l /tmp/seed.log start

          runuser -u postgres -- ${oldPkg}/bin/psql -h /run/pgseed -U postgres -v ON_ERROR_STOP=1 -d postgres <<'SQL'
            CREATE DATABASE shop;
            CREATE ROLE appuser LOGIN PASSWORD 'secret';
          SQL

          runuser -u postgres -- ${oldPkg}/bin/psql -h /run/pgseed -U postgres -v ON_ERROR_STOP=1 -d shop <<'SQL'
            CREATE EXTENSION vector;
            CREATE TABLE items (
              id serial PRIMARY KEY,
              name text NOT NULL,
              embedding vector(3)
            );
            INSERT INTO items (name, embedding)
              SELECT 'item-' || g, ('[' || g || ',' || g || ',' || g || ']')::vector
              FROM generate_series(1, ${toString rows}) g;
            CREATE INDEX items_name_idx ON items (name);
            CREATE MATERIALIZED VIEW items_mv AS SELECT count(*) AS n FROM items;
            GRANT SELECT ON items TO appuser;
          SQL

          runuser -u postgres -- ${oldPkg}/bin/pg_ctl -D ${dataDir} -w -t 120 -m fast stop
          echo "seeded ${oldPkg.psqlSchema} cluster"
        '';
      };
    };

  testScript = ''
    machine.start()

    with subtest("the old cluster was seeded and then upgraded"):
        machine.wait_for_unit("seed-old-cluster.service")
        # Surface the upgrade's own step-by-step log before asserting on it;
        # otherwise a failure here is just an opaque "unit failed".
        print(machine.execute(
            "journalctl -u postgresql-major-upgrade.service --no-pager -o cat"
        )[1])
        machine.wait_for_unit("postgresql-major-upgrade.service")
        machine.wait_for_unit("postgresql.service")

    with subtest("cluster now reports the new major version"):
        version = machine.succeed("cat ${dataDir}/PG_VERSION").strip()
        assert version == "${newPkg.psqlSchema}", f"expected ${newPkg.psqlSchema}, got {version}"

    with subtest("the running server is the new major"):
        served = machine.succeed(
            "sudo -u postgres psql -X -A -t -c 'SHOW server_version'"
        ).strip()
        assert served.startswith("${newPkg.psqlSchema}"), f"server reports {served}"

    with subtest("all rows survived"):
        n = machine.succeed(
            "sudo -u postgres psql -X -A -t -d shop -c 'SELECT count(*) FROM items'"
        ).strip()
        assert n == "${toString rows}", f"expected ${toString rows} rows, got {n}"

    with subtest("the extension came across and still works"):
        machine.succeed(
            "sudo -u postgres psql -X -A -t -d shop "
            "-c \"SELECT 1 FROM pg_extension WHERE extname='vector'\" | grep -q 1"
        )
        nearest = machine.succeed(
            "sudo -u postgres psql -X -A -t -d shop "
            "-c \"SELECT name FROM items ORDER BY embedding <-> '[1,1,1]' LIMIT 1\""
        ).strip()
        assert nearest == "item-1", f"vector search returned {nearest}"

    with subtest("indexes, matviews, roles and grants survived"):
        machine.succeed(
            "sudo -u postgres psql -X -A -t -d shop "
            "-c \"SELECT 1 FROM pg_indexes WHERE indexname='items_name_idx'\" | grep -q 1"
        )
        machine.succeed(
            "sudo -u postgres psql -X -A -t -d shop "
            "-c \"SELECT 1 FROM pg_matviews WHERE matviewname='items_mv'\" | grep -q 1"
        )
        machine.succeed(
            "sudo -u postgres psql -X -A -t "
            "-c \"SELECT 1 FROM pg_roles WHERE rolname='appuser'\" | grep -q 1"
        )
        machine.succeed(
            "sudo -u postgres psql -X -A -t -d shop "
            "-c \"SELECT has_table_privilege('appuser','items','SELECT')\" | grep -q t"
        )

    with subtest("collation ordering is intact"):
        first = machine.succeed(
            "sudo -u postgres psql -X -A -t -d shop "
            "-c 'SELECT name FROM items ORDER BY name LIMIT 1'"
        ).strip()
        assert first == "item-1", f"ordering returned {first}"

    with subtest("no collation version mismatch remains"):
        mismatch = machine.succeed(
            "sudo -u postgres psql -X -A -t "
            "-c \"SELECT count(*) FROM pg_database d WHERE d.datallowconn AND "
            "d.datcollversion IS DISTINCT FROM pg_database_collation_actual_version(d.oid)\""
        ).strip()
        assert mismatch == "0", f"{mismatch} databases have a stale collation version"

    with subtest("the pre-upgrade dump and old cluster were preserved"):
        machine.succeed("ls ${backupDir}/dumpall-17-to-${newPkg.psqlSchema}-*.sql")
        machine.succeed("ls -d ${dataDir}.major-17-*")

    with subtest("re-running the upgrade does not take postgres down"):
        # The upgrade is only Wants=, and postgres is guarded by its own
        # preStart check, so a manual re-run must leave the database serving.
        machine.succeed("systemctl restart postgresql-major-upgrade.service")
        machine.succeed("systemctl is-active postgresql-major-upgrade.service")
        machine.succeed("systemctl is-active postgresql.service")
        machine.succeed("sudo -u postgres psql -X -A -t -c 'SELECT 1' | grep -q 1")

    with subtest("the upgrade is idempotent"):
        n = machine.succeed(
            "sudo -u postgres psql -X -A -t -d shop -c 'SELECT count(*) FROM items'"
        ).strip()
        assert n == "${toString rows}", f"rows changed after re-run: {n}"
        dumps = machine.succeed("ls ${backupDir} | grep -c '^dumpall-' || true").strip()
        assert dumps == "1", f"expected exactly 1 dump, found {dumps}"
  '';
}
