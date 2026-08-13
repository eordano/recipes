{
  pkgs ? import <nixpkgs> { },
}:

let
  pg = import ./default.nix { inherit pkgs; };

  writeMigrations =
    name: files:
    pkgs.runCommand name { } (
      "mkdir -p $out\n"
      + pkgs.lib.concatStrings (
        pkgs.lib.mapAttrsToList (fn: sql: "cp ${pkgs.writeText fn sql} \"$out/${fn}\"\n") files
      )
    );

  base = writeMigrations "demo-migrations-base" {
    "0001-init.sql" = "CREATE TABLE IF NOT EXISTS widgets (id serial PRIMARY KEY, name text);";
    "0002-add-color.sql" = "ALTER TABLE widgets ADD COLUMN IF NOT EXISTS color text;";
  };

  extended = writeMigrations "demo-migrations-extended" {
    "0001-init.sql" = "CREATE TABLE IF NOT EXISTS widgets (id serial PRIMARY KEY, name text);";
    "0002-add-color.sql" = "ALTER TABLE widgets ADD COLUMN IF NOT EXISTS color text;";
    "0003-add-size.sql" = "ALTER TABLE widgets ADD COLUMN IF NOT EXISTS size int;";
  };

  broken = writeMigrations "demo-migrations-broken" {
    "0001-init.sql" = "CREATE TABLE IF NOT EXISTS widgets (id serial PRIMARY KEY, name text);";
    "0002-add-color.sql" = "ALTER TABLE widgets ADD COLUMN IF NOT EXISTS color text;";
    "0004-bad.sql" = ''
      CREATE TABLE gadgets (id serial PRIMARY KEY);
      THIS IS NOT VALID SQL;
    '';
  };

  migrateBase = pg.mkMigrate {
    name = "migrate-base";
    migrations = base;
    database = "app";
  };
  migrateExtended = pg.mkMigrate {
    name = "migrate-ext";
    migrations = extended;
    database = "app";
  };
  migrateBroken = pg.mkMigrate {
    name = "migrate-broken";
    migrations = broken;
    database = "app";
  };
in
pkgs.nixosTest {
  name = "postgresql-migration-ledger";

  nodes.machine = { ... }: {
    services.postgresql = {
      enable = true;
      ensureDatabases = [ "app" ];
    };
  };

  testScript = ''
    machine.wait_for_unit("postgresql.service")

    def rows(q):
        return machine.succeed(
            f"sudo -u postgres psql -tAd app -c \"{q}\""
        ).strip()

    def ledger_count():
        return rows("select count(*) from public.schema_migrations")

    def has(fn):
        return rows(
            f"select exists(select 1 from public.schema_migrations where filename = '{fn}')"
        )

    # First run: both base migrations apply, ledger has exactly two rows.
    machine.succeed("${migrateBase}/bin/migrate-base")
    assert ledger_count() == "2", f"expected 2 ledger rows, got {ledger_count()}"
    assert has("0001-init.sql") == "t"
    assert has("0002-add-color.sql") == "t"

    # Second run: nothing new, schema intact.
    out = machine.succeed("${migrateBase}/bin/migrate-base")
    assert "skipping 0001-init.sql" in out
    assert ledger_count() == "2", "second run should not add rows"
    assert rows("select count(*) from information_schema.columns "
                "where table_name='widgets' and column_name='color'") == "1"

    # Extended set: 0001/0002 are already recorded, yet 0003 still lands. This
    # is the per-file property -- a sentinel would have skipped 0003 forever.
    out = machine.succeed("${migrateExtended}/bin/migrate-ext")
    assert "skipping 0001-init.sql" in out
    assert "applying 0003-add-size.sql" in out
    assert ledger_count() == "3"
    assert has("0003-add-size.sql") == "t"

    # Broken migration: the whole 0004 transaction rolls back. Neither its table
    # nor its ledger row survives, and the run exits non-zero.
    machine.fail("${migrateBroken}/bin/migrate-broken")
    assert has("0004-bad.sql") == "f", "a failed migration must not be recorded"
    assert rows("select exists(select 1 from information_schema.tables "
                "where table_name='gadgets')") == "f", \
        "the CREATE in a failed migration must roll back with the INSERT"
    assert ledger_count() == "3", "ledger unchanged after a failed migration"
  '';
}
