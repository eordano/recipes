# postgresql-migration-ledger

A small Nix helper that applies a directory of `NNNN-name.sql` files to a
PostgreSQL database idempotently. It records each file in a per-file ledger
table and applies the file together with its ledger row inside one
`psql --single-transaction`, so a partly-applied migration is never marked done.

## The problem

You ship a database schema as a set of ordered SQL files and want a boot-time
unit that brings any database -- fresh or already half-migrated -- up to the
current set, exactly once each, and never half-way. The naive versions of this
fail in three quiet, expensive ways.

The first is the one that actually bites in production. A guard like "if the
marker table from `0001` exists, we are migrated, exit" works perfectly until
you add `0003`. Every database that has ever run `0001` now reports "migrated"
and silently skips `0003` -- and `0004`, and everything after -- **forever**. The
unit is green, the newest migrations never land, and the breakage surfaces as a
missing column somewhere far from the migration code. A single all-or-nothing
sentinel row is the same bug wearing a table.

The second is a `psql` sharp edge. The obvious way to test "have we applied this
file?" is to pass the filename as a variable and let `psql` quote it:

```
psql -v name="$name" -c "select ... where filename = :'name'"     # :'name' NOT expanded
psql -v name="$name" -tAf - <<<"select ... where filename = :'name'"  # :'name' expanded
```

`psql` interpolates `:'name'` (and `:name`, `:"name"`) only for input read from
a **file or stdin**. For `-c` the literal four characters `:'name'` are sent to
the server, which either errors or, worse, matches nothing and quietly reports
"not applied" for every file. So the variable-bearing statements have to go in
on stdin, never through `-c`.

The third is atomicity. If you apply the file and then, as a second command,
record it in the ledger, a crash (OOM, restart, `\q`, a failing later statement)
between the two leaves a migration that ran but was never recorded -- or, with
the order reversed, recorded but never ran. Either way the next boot does the
wrong thing. The file and its ledger `INSERT` must commit or roll back together.

## The approach

One ledger table, one row per file, and one transaction per file that carries
both the migration and its bookkeeping:

```sh
psql -c "CREATE TABLE IF NOT EXISTS public.schema_migrations (
    filename   text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);"

for f in "$migrations"/*.sql; do
  name=$(basename "$f")

  # existence probe on stdin, so :'name' is expanded and safely quoted
  applied=$(echo "select exists(select 1 from public.schema_migrations
                                 where filename = :'name');" \
    | psql -v name="$name" -tAf -)
  [ "$applied" = t ] && continue

  # file THEN its INSERT, both under --single-transaction: all or nothing
  echo "INSERT INTO public.schema_migrations (filename) VALUES (:'name');" \
    | psql -v name="$name" --single-transaction -f "$f" -f -
done
```

The `*.sql` glob expands in sorted order, which is what makes the `NNNN-`
prefixes meaningful -- name your files `0001-...`, `0002-...` and they apply in
that order. The loop runs under `shopt -s nullglob`, so a migrations directory
that is empty or absent produces zero iterations and a clean exit, rather than
the loop running once against the literal string `*.sql` and crashing in
`basename`. `mkMigrate` is exactly this loop with the database, ledger table and
migrations directory baked in at build time.

```nix
let pg = import ./lib/postgresql-migration-ledger { inherit pkgs; }; in
{
  systemd.services.app-migrate = pg.mkMigrateService {
    name = "app-migrate";
    migrations = "${pkgs.myapp}/share/myapp/migrations";
    database = "app";
    user = "postgres";           # peer auth over the local socket
  };
}
```

or standalone, as a package you can run by hand:

```nix
pg.mkMigrate {
  name = "app-migrate";
  migrations = ./migrations;
  database = "app";
  ledgerTable = "public.app_schema_migrations";
}
```

## Traps the helper is shaped around

**1. The ledger is per file, not a sentinel.** The `filename text PRIMARY KEY`
is the entire point. Do not "optimise" it into a single boolean, a version
number you bump, or a check for one marker table -- each of those makes every
migration added after the marker was first written look already applied, on
every database that has run the marker, permanently. The failure is invisible
because the unit still exits 0; you find it later as a missing column. If you
must reason about a version number, derive it from `max(filename)` in the
ledger; keep the row-per-file underneath.

**2. `:'name'` only expands from a file or stdin, never from `-c`.** This is why
both variable-bearing statements -- the existence probe and the `INSERT` -- are
piped in and read with `-f -` rather than passed with `-c`. `psql` variable
interpolation (`:name`, `:'name'`, `:"name"`) is a feature of the input
processor that reads scripts, and `-c` bypasses it. Build the SQL string with
the variable syntax and let `psql` do the quoting; do not `printf` the filename
into the SQL yourself, and do not reach for `-c` "just for the probe".

**3. The file and its ledger row share one transaction.** `--single-transaction`
with `-f "$f" -f -` wraps the migration file and the trailing `INSERT` (on
stdin) in a single `BEGIN`/`COMMIT`. If any statement in the file fails, the
ledger row is never written, so the next run retries the file from a clean
state. If instead you ran the file and then recorded it as two separate `psql`
invocations, a crash in the gap would record a migration that had not fully
applied -- and because it is now in the ledger, it would never be retried. The
order matters too: file first, `INSERT` last, so the row is only reached if the
migration itself parsed and ran.

**4. `--single-transaction` forbids statements that cannot run in a transaction
block.** `CREATE INDEX CONCURRENTLY`, `CREATE DATABASE`, `VACUUM`, `ALTER TYPE
... ADD VALUE` (before PostgreSQL 12), and `ALTER SYSTEM` will error with
`cannot run inside a transaction block` when wrapped this way. That is a
deliberate constraint of this recipe, not a bug: a migration that cannot be
atomic cannot honour trap 3. If you genuinely need one, apply it as its own
step outside this helper and record it in the ledger yourself, understanding
that it is not crash-safe.

**5. Re-running a file must be harmless in the adoption case.** The ledger stops
already-recorded files from re-running, but the *first* run against a database
that predates the ledger will apply `0001` and `0002` to a schema that may
already have their objects. Write your DDL as `CREATE TABLE IF NOT EXISTS` /
`ADD COLUMN IF NOT EXISTS` so that first adoption pass is a no-op rather than a
`relation already exists` failure. After adoption every file runs exactly once
regardless.

**6. Who runs the unit decides how it authenticates.** The script connects with
`-h /run/postgresql` (the local socket) and no password, which relies on
`peer` authentication: the system user must map to a PostgreSQL role with
access to the database. Run the service as `postgres` (or as the role that owns
the database); `mkMigrateService`'s `user` argument sets `User=`. Nothing here
creates the database, the role, or grants -- order the unit `after` and
`requires` PostgreSQL, and make sure the database exists first (for example via
`services.postgresql.ensureDatabases`).

## API

`import ./lib/postgresql-migration-ledger { inherit pkgs; }` returns:

| attribute | meaning |
|-----------|---------|
| `mkMigrate` | `{ ... } -> package` exposing `bin/<name>`, the migration loop |
| `mkMigrateService` | same arguments plus `user` / `group` / `serviceConfig`; returns a value for `systemd.services.<name>` |

`mkMigrate` arguments:

| argument | default | meaning |
|----------|---------|---------|
| `migrations` | *(required)* | Directory containing `NNNN-name.sql` files; applied in glob (sorted) order. |
| `database` | *(required)* | Database name passed to `psql -d`. |
| `name` | `"pg-migrate"` | Binary and derivation name. |
| `ledgerTable` | `"public.schema_migrations"` | Qualified ledger table name; created `IF NOT EXISTS`. Injected into the SQL at build time -- keep it a static, trusted string. |
| `host` | `"/run/postgresql"` | `psql -h`; a socket directory for peer auth, or a hostname. |
| `port` | `null` | Adds `-p <port>` when set. |
| `psql` | `pkgs.postgresql` | Package providing `bin/psql`. Match your server's major version. |
| `extraArgs` | `[ ]` | Extra `psql` flags appended to the base invocation. |

`mkMigrateService` additionally accepts `user`, `group`, and a `serviceConfig`
attrset that is merged over the defaults (`Type = "oneshot"`,
`RemainAfterExit = true`, and `ExecStart`). It also sets `after` / `requires` /
`wantedBy` for `postgresql.service`.

## Test

`test-migration-ledger.nix` is a NixOS VM test that boots PostgreSQL and asserts
all three properties: a later migration lands even though earlier ones are
already in the ledger (per-file, not sentinel), a second run applies nothing and
leaves the schema intact (idempotence), and a migration that fails half-way
records no ledger row and leaves none of its objects behind (atomicity).

```sh
nix-build ./lib/postgresql-migration-ledger/test-migration-ledger.nix
```

## Caveats

- The `migrations` directory is read at *runtime* from the store path you pass,
  not inlined at evaluation time. It must be a store path (or an absolute path)
  that exists when the unit runs; a relative path resolves against the working
  directory of the service, which you do not control.
- `ON_ERROR_STOP=1` is always set, so any error in the probe or the migration
  aborts the run with a non-zero exit. That is what makes the unit's failure
  honest -- do not add `|| true`.
- The ledger records *that* a file ran, not its contents or a checksum. Editing
  a file that has already been applied will not re-run it. Treat applied
  migrations as immutable and add a new `NNNN-` file for further changes.
- Nothing here manages roles, ownership, or grants, and the migrations run with
  whatever privileges the connecting role has. A migration run as `postgres` can
  do anything; scope the role if that matters to you.
