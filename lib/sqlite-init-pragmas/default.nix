# sqlite-init-pragmas
#
# Run a pragma + schema stream against a sqlite database without losing the
# schema.
#
# `sqlite3 -bail -cmd 'PRAGMA ...;' db.sqlite <statements>` runs the pragma and
# then exits 0 WITHOUT running the statements -- whether they arrive as a
# trailing argument, on stdin, or through a trailing `.read`. See README.md for
# the reproducer and the upstream source line that does it.
#
# So: never `-cmd`. The pragmas are prepended to the statement stream and the
# whole thing goes in on stdin as ordinary SQL, in one connection, with one exit
# status.
#
#   init = (import ./lib/sqlite-init-pragmas { inherit pkgs; }).mkSqliteInit {
#     name = "app-db-init";
#     database = "/var/lib/app/app.db";
#     sqlFiles = [ ./schema.sql ];
#   };
#   # -> a package; run `${init}/bin/app-db-init [database]`.

{
  pkgs,
  lib ? pkgs.lib,
}:

let
  inherit (lib)
    concatMapStrings
    concatStringsSep
    elem
    escapeShellArg
    escapeShellArgs
    mapAttrsToList
    optionalString
    ;

  # `PRAGMA x = ON;` reads better than `= 1` and sqlite accepts both. Ints and
  # strings pass through untouched so any pragma value is expressible.
  renderValue =
    v:
    if v == true then
      "ON"
    else if v == false then
      "OFF"
    else
      toString v;

  defaultPragmas = {
    busy_timeout = 5000;
    foreign_keys = true;
    journal_mode = "WAL";
  };

  # -bail: stop at the first failing statement instead of applying the rest of
  #        the schema on top of a broken step.
  # -noinit: do not consult an rc file; a schema init must not depend on
  #        whatever ambient config the invoking user happens to have.
  defaultFlags = [
    "-bail"
    "-noinit"
  ];

  mkSqliteInit =
    {
      name ? "sqlite-init",
      database,
      pragmas ? defaultPragmas,
      statements ? "",
      sqlFiles ? [ ],
      transaction ? true,
      flags ? defaultFlags,
      sqlite ? pkgs.sqlite,
      directoryMode ? "0755",
    }:
    let
      # The whole point of the recipe. Passing a pragma here would silently
      # discard everything below it.
      # sqlite3 strips one leading dash before matching (src/shell.c.in:13345),
      # so `--cmd` is the same option and must be rejected too.
      guard =
        if elem "-cmd" flags || elem "--cmd" flags then
          throw (
            "sqlite-init-pragmas: `-cmd` in `flags` for '${name}'. Together with -bail it makes "
            + "sqlite3 exit 0 after the -cmd and run none of the statements. Put the pragma in "
            + "`pragmas` instead."
          )
        else
          x: x;

      # Pragmas first, and OUTSIDE any transaction: `PRAGMA journal_mode = WAL`
      # fails inside one, and `PRAGMA foreign_keys` is a silent no-op inside one.
      pragmaFile = pkgs.writeText "${name}-pragmas.sql" (
        concatStringsSep "\n" (mapAttrsToList (n: v: "PRAGMA ${n} = ${renderValue v};") pragmas) + "\n"
      );

      statementFile = pkgs.writeText "${name}-statements.sql" (
        optionalString transaction "BEGIN;\n"
        + concatMapStrings (f: "${builtins.readFile f}\n") sqlFiles
        + statements
        + "\n"
        + optionalString transaction "COMMIT;\n"
      );
    in
    guard (
      pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = [
          sqlite
          pkgs.coreutils
        ];
        text = ''
          db=''${1:-${escapeShellArg database}}
          dir=$(dirname "$db")
          # Only on creation: an unconditional `install -d -m` would widen an
          # existing 0700 StateDirectory to directoryMode.
          [ -d "$dir" ] || install -d -m ${escapeShellArg directoryMode} "$dir"

          cat ${pragmaFile} ${statementFile} | sqlite3 ${escapeShellArgs flags} "$db"
        '';
      }
    );

  # Same arguments, wrapped as a value for `systemd.services.<name>`.
  mkSqliteInitService =
    args@{
      name ? "sqlite-init",
      user ? null,
      group ? null,
      ...
    }:
    let
      init = mkSqliteInit (
        removeAttrs args [
          "user"
          "group"
          "serviceConfig"
        ]
      );
    in
    {
      description = "Initialise the ${name} sqlite database";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${init}/bin/${name}";
      }
      // lib.optionalAttrs (user != null) { User = user; }
      // lib.optionalAttrs (group != null) { Group = group; }
      // (args.serviceConfig or { });
    };

  # Regression test for the behaviour the README describes. Build with:
  #
  #   nix build --impure --expr '
  #     let pkgs = import <nixpkgs> {}; in
  #     (import ./lib/sqlite-init-pragmas { inherit pkgs; }).tests.cmdSuppression'
  tests.cmdSuppression =
    pkgs.runCommand "sqlite-init-pragmas-test"
      {
        nativeBuildInputs = [ pkgs.sqlite ];
        schema = pkgs.writeText "schema.sql" ''
          CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL);
        '';
        helper = mkSqliteInit {
          name = "demo-init";
          database = "/var/empty/unused.db";
          statements = "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL);";
        };
      }
      ''
        set -eu
        cd "$(mktemp -d)"
        tables() { sqlite3 "$1" "SELECT count(*) FROM sqlite_master WHERE type='table'"; }

        echo "sqlite3: $(sqlite3 --version)"

        # 1. -cmd + -bail: the trailing statement never runs, exit status 0.
        got=$(sqlite3 -bail -cmd 'PRAGMA busy_timeout = 5000;' a.db 'SELECT 42')
        [ "$got" = "5000" ] || { echo "expected 5000, got $got"; exit 1; }

        # 2. Same with a schema on stdin: zero tables, exit status 0.
        sqlite3 -bail -cmd 'PRAGMA journal_mode = WAL;' b.db < "$schema" > /dev/null
        [ "$(tables b.db)" = "0" ] || { echo "expected the -cmd form to drop the schema"; exit 1; }

        # 3. Without -bail the trailing statements do run -- bail_on_error is the trigger.
        got=$(sqlite3 -cmd 'PRAGMA busy_timeout = 5000;' c.db 'SELECT 42' | tr '\n' ',')
        [ "$got" = "5000,42," ] || { echo "expected 5000,42, got $got"; exit 1; }

        # 4. Prepended pragmas: the schema IS applied and the pragma IS in effect.
        "$helper/bin/demo-init" "$PWD/helper.db" > /dev/null
        [ "$(tables helper.db)" = "1" ] || { echo "helper did not create the table"; exit 1; }
        [ "$(sqlite3 helper.db 'PRAGMA journal_mode')" = "wal" ] || { echo "helper did not set WAL"; exit 1; }

        # 5. A broken statement mid-stream is fatal, unlike the silent -cmd case.
        if printf 'CREATE TABLE ok(a);\nTHIS IS NOT SQL;\n' | sqlite3 -bail -noinit d.db 2>/dev/null; then
          echo "expected a non-zero exit for a broken statement"; exit 1
        fi

        # 6. journal_mode outlives the connection, foreign_keys does not.
        printf 'PRAGMA journal_mode = WAL;\nPRAGMA foreign_keys = ON;\nCREATE TABLE t(a);\n' \
          | sqlite3 -bail -noinit e.db > /dev/null
        [ "$(sqlite3 e.db 'PRAGMA journal_mode')" = "wal" ] || { echo "journal_mode did not persist"; exit 1; }
        [ "$(sqlite3 e.db 'PRAGMA foreign_keys')" = "0" ] || { echo "foreign_keys unexpectedly persisted"; exit 1; }

        touch "$out"
      '';
in
{
  inherit
    mkSqliteInit
    mkSqliteInitService
    defaultPragmas
    defaultFlags
    tests
    ;
}
