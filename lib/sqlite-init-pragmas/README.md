# sqlite-init-pragmas

A small Nix helper for applying a schema (or any statement stream) to a sqlite
database with pragmas set. It prepends the pragmas to the statement stream
instead of passing them as `sqlite3 -cmd`, because a SQL `-cmd` combined with
`-bail` -- which this helper sets, and which you want set -- silently throws the
statements away.

Everything below was observed on **sqlite 3.53.3 (2026-06-26)**, both from the
shell on `PATH` and through `pkgs.sqlite`, which was the same version. Source
line numbers are repo-relative paths into `sqlite-src-3530300`.

## The problem

Two lines, five seconds, your own sqlite:

```
$ sqlite3 -bail -cmd 'PRAGMA busy_timeout = 5000;' db 'SELECT 42'
5000
$ sqlite3 -bail db 'SELECT 42'
42
```

The first form prints `5000` and **not** `42`, and exits 0. The statement you
actually wanted to run never ran, and nothing said so.

It is not a quirk of trailing SQL arguments. With `-bail` set, adding a `-cmd`
suppresses the real statements no matter how they arrive:

| how the statements arrive | without `-cmd`  | with `-cmd 'PRAGMA ...;'` |
|---------------------------|-----------------|---------------------------|
| trailing SQL argument     | `42`            | pragma output only, exit 0 |
| schema piped on stdin     | tables created  | **zero tables**, exit 0    |
| schema via heredoc        | tables created  | **zero tables**, exit 0    |
| trailing `.read schema.sql` | tables created | **zero tables**, exit 0   |

Exit status is 0 in every one of those cells, stderr is empty, and the database
file exists. The only visible output is the pragma's own.

This is the shape of a real failure: a oneshot unit that creates a schema
"succeeds", leaves an empty database behind, and every dependent service then
fails somewhere far away from the cause. `journal_mode`, `foreign_keys` and
`busy_timeout` are exactly the settings people reach for `-cmd` to apply, so the
idiom is common and the failure is invisible.

## Why: it is `-cmd` *plus* `-bail`

`-cmd` on its own is fine. Drop `-bail` and both halves run:

```
$ sqlite3 -cmd 'PRAGMA busy_timeout = 5000;' db 'SELECT 42'
5000
42
```

`src/shell.c.in:13501-13517` is the whole story:

```c
    }else if( cli_strcmp(z,"-cmd")==0 ){
      /* Run commands that follow -cmd first and separately from commands
      ** that simply appear on the command-line.  This seems goofy.  It would
      ** be better if all commands ran in the order that they appear.  But
      ** we retain the goofy behavior for historical compatibility. */
      if( i==argc-1 ) break;
      z = cmdline_option_value(argc,argv,++i);
      if( z[0]=='.' ){
        rc = do_meta_command(z, &data);
        if( rc && (bail_on_error || rc==2) ){
          if( rc==2 ) rc = 0;
          goto shell_main_exit;
        }
      }else{
        rc = runOneSqlLine(&data, z, "cmdline", i);
        if( bail_on_error ) goto shell_main_exit;
      }
```

The last line is unconditional on `rc`. A non-dot `-cmd` under `bail_on_error`
jumps straight to the cleanup label at `:13655`, past the `if( !readStdin )`
block at `:13549` that runs the trailing arguments and past the
`process_input(&data, "<stdin>")` calls that read stdin. `rc` is still 0, so the
process exits 0.

Four consequences worth knowing:

- **Dot-commands are unaffected.** `-cmd '.bail on'` or `-cmd '.mode json'` goes
  down the `do_meta_command` branch, which only bails when the command itself
  failed. Only the SQL form of `-cmd` is destructive.
- **Where `-bail` sits on the command line does not matter.** It is handled in
  the *first* argument pass (`:13227`, inside the pass beginning at `:13058`),
  while `-cmd` is handled in the second (`:13337` onward). `sqlite3 -cmd
  'PRAGMA busy_timeout = 5000;' db 'SELECT 42' -bail` still prints only `5000`.
  So does `-cmd '.bail on' -cmd 'PRAGMA busy_timeout = 5000;' db 'SELECT 42'`:
  the dot-command sets the flag, the next `-cmd` trips over it.
- **Only the first SQL `-cmd` runs.** `-cmd 'SELECT 1;' -cmd 'SELECT 2;' db
  'SELECT 3'` under `-bail` prints `1` and nothing else.
- **The pragma does take effect** on the connection before the exit -- `-cmd
  'PRAGMA journal_mode = WAL;'` really does leave the file in WAL mode. That is
  what makes it convincing: the one thing you can see working is the one thing
  that worked.

Errors *inside* the `-cmd` are reported normally
(`Parse error in 3rd command line argument: no such table: nope`, exit 1). The
silence is specific to everything that was supposed to come after.

Note the upstream comment: the ordering is called "goofy" and kept "for
historical compatibility". Do not expect it to change.

## The fix

Put the pragmas in the statement stream, where they are just SQL:

```sh
{ echo 'PRAGMA journal_mode = WAL;'; cat schema.sql; } | sqlite3 -bail db
```

One connection, one input stream, one exit status. `mkSqliteInit` is that
pipeline, with the stream assembled at build time.

```nix
let sq = import ./lib/sqlite-init-pragmas { inherit pkgs; }; in
{
  systemd.services.app-db-init = sq.mkSqliteInitService {
    name = "app-db-init";
    database = "/var/lib/app/app.db";
    sqlFiles = [ ./schema.sql ];
    user = "app";
  };
}
```

or standalone, as a package with the database name overridable by argument:

```nix
sq.mkSqliteInit {
  name = "app-db-init";
  database = "/var/lib/app/app.db";
  pragmas = sq.defaultPragmas // { synchronous = "NORMAL"; };
  statements = "CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY);";
}
```

Passing `-cmd` in `flags` is an evaluation error, not a runtime surprise.

## Traps the helper is shaped around

**1. Pragmas go outside the transaction.** The statements are wrapped in
`BEGIN;`/`COMMIT;` (set `transaction = false` if your SQL brings its own -- a
nested `BEGIN` is `cannot start a transaction within a transaction`). The
pragmas are emitted *before* that `BEGIN`, because inside a transaction they
misbehave in two different ways:

```
BEGIN; PRAGMA journal_mode = WAL;  ->  Error near line 2: cannot change into
                                       wal mode from within a transaction
BEGIN; PRAGMA foreign_keys = ON;   ->  no error at all; foreign_keys reads 0
```

The first is loud. The second is the dangerous one: `PRAGMA foreign_keys` is a
no-op inside a transaction -- no error, and `SELECT * FROM pragma_foreign_keys`
returns `0` on the next line -- so a schema loaded that way is checked with
foreign keys *off* while the script looks entirely correct.

**2. Some pragmas persist, most do not.** `journal_mode = WAL` is written into
the database header and every later connection sees `wal`. `foreign_keys` is
per-connection: after the init script exits, a fresh connection reads `0` again.
An init script therefore cannot "turn foreign keys on for the database" -- it can
only have them on while it applies its own schema. The application must set it
on each connection it opens. Setting it here is still worth it, because it is
what makes the init stream itself enforce the constraints it declares.

**3. `-bail` still matters after the fix.** Without it a broken statement in the
middle of the stream is skipped and the *rest of the schema is applied anyway*:
a stream of `CREATE TABLE u`, a syntax error, `CREATE TABLE w` leaves both `u`
and `w` behind. With `-bail` it leaves only `u`. Both exit 1; only one of them
is a state you can reason about.

**4. Re-runs are your problem.** The helper does not rewrite your DDL. Running a
plain `CREATE TABLE t (...)` stream a second time exits 1 with `table t already
exists`. Write `CREATE TABLE IF NOT EXISTS`, or guard the unit with
`ConditionPathExists=!<database>`, or accept the failure as a signal.

**5. `-init FILE` is the other honest option.** Unlike `-cmd`, an `-init` file's
pragmas run *and* the trailing statements still run. With `init.sql` containing
`PRAGMA busy_timeout = 5000;`, `sqlite3 -bail -init init.sql db 'SELECT 42'`
prints `5000` then `42`, and the same file with a schema on stdin creates the
tables and leaves the pragma applied. It goes through
`process_input` and only aborts on error (`:12729`). It is not used here because
it needs a second file and splits one logical stream into two, but it is a
correct fix if you already have such a file.

The default flags include `-noinit`. `process_sqliterc` runs unless that flag is
given (`:13335`), and a database initialiser should not be able to pick up
statements from whatever rc file happens to exist for the invoking user.

## API

`import ./lib/sqlite-init-pragmas { inherit pkgs; }` returns:

| attribute | meaning |
|-----------|---------|
| `mkSqliteInit` | `{ ... } -> package` exposing `bin/<name>`, taking an optional database path argument |
| `mkSqliteInitService` | same arguments plus `user` / `group` / `serviceConfig`; returns a value for `systemd.services.<name>` |
| `defaultPragmas` | `{ busy_timeout = 5000; foreign_keys = true; journal_mode = "WAL"; }` |
| `defaultFlags` | `[ "-bail" "-noinit" ]` |
| `tests.cmdSuppression` | the regression test described below |

`mkSqliteInit` arguments:

| argument | default | meaning |
|----------|---------|---------|
| `database` | *(required)* | Path the script writes to; overridable by `$1` at runtime. Its parent directory is created. |
| `name` | `"sqlite-init"` | Binary and derivation name. |
| `pragmas` | `defaultPragmas` | Attrset. `true`/`false` render as `ON`/`OFF`, everything else via `toString`. |
| `statements` | `""` | Inline SQL, appended after `sqlFiles`. |
| `sqlFiles` | `[ ]` | Paths whose contents are inlined, in order. |
| `transaction` | `true` | Wrap the statements (never the pragmas) in `BEGIN;`/`COMMIT;`. |
| `flags` | `defaultFlags` | `sqlite3` flags. `-cmd` here throws. |
| `sqlite` | `pkgs.sqlite` | |
| `directoryMode` | `"0755"` | Mode for the parent directory, applied only when the script creates it. An existing directory keeps its mode. |

Because `pragmas` is an attrset, the pragmas are emitted in alphabetical order.
No ordering dependency exists among the pragmas people normally set here; if you
need one, emit them yourself as leading `statements` with `pragmas = { }`.

## Self-test

```sh
nix build --impure --expr '
  let pkgs = import <nixpkgs> {}; in
  (import ./lib/sqlite-init-pragmas { inherit pkgs; }).tests.cmdSuppression'
```

Six assertions, all of them facts stated above: the trailing-argument case, the
stdin case, that dropping `-bail` makes both halves run, that the helper's
prepended-pragma stream applies the schema *and* leaves the file in WAL mode,
that a broken statement mid-stream is fatal, and that `journal_mode` outlives
the connection while `foreign_keys` does not.

## Caveats

- `sqlFiles` are read with `builtins.readFile`, so they must be readable at
  evaluation time. Their contents are concatenated into one world-readable store
  file, as is `statements` -- do not put credentials in either.
- The database path is baked in as a default only; the script accepts an
  overriding path as `$1`, which is what makes it testable and what the
  self-test uses.
- Nothing here creates the database *user* or manages ownership beyond the
  optional `User=`/`Group=` on the service. A database created by a `root`
  oneshot is owned by root.
- The behaviour documented here is a property of the `sqlite3` shell, not of
  libsqlite3. Bindings that set pragmas over an open connection are unaffected.
