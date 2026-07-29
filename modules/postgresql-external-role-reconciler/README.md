# postgresql-external-role-reconciler

A NixOS module that drives **role passwords, database ownership and read-only
grants into a PostgreSQL server this host does not run**: a managed cloud
instance, a Patroni cluster behind a leader proxy, a database VM on the far side
of a VPN.

Secrets come from files (agenix, sops-nix, anything that lands a file on disk),
are handed to systemd as `LoadCredential`, are re-applied automatically when the
secret rotates, and every consumer of the credential is ordered *after* — and by
default `Requires=` — the reconciler, so nothing can start against a role whose
password was never applied.

## The problem

Your app needs a password for its database role. The database is not on this
host. So the password has to exist in two places at once — in the secret file the
app reads, and inside `pg_authid` on a server you only reach over the network —
and those two have to stay equal across rotations, reboots and rebuilds.

The obvious NixOS answer is `services.postgresql.ensureUsers`. It cannot do this.

## What upstream nixpkgs does NOT do

Citations are to nixpkgs **26.11** (2026-07),
`nixos/modules/services/databases/postgresql.nix`.

**1. `ensureUsers` is local-only — it is inert without a local server.**
The entire config body of the module is behind `config = mkIf cfg.enable`
(**:609**). Setting `services.postgresql.ensureUsers` without
`services.postgresql.enable = true` produces *nothing at all* — no unit, no
warning, no assertion. It fails silently and looks like it worked.

**2. Even enabled, it can only ever talk to the local socket.**
The unit that applies it is `postgresql-setup` (**:870**), which
`requires`/`after` the local `postgresql.service` (**:873-874**), runs as the
local `postgres` unix user (**:877**), and is given exactly one connection
parameter: `environment.PGPORT` (**:884**). No `PGHOST`, no `PGUSER`, no
`PGPASSWORD` — every `psql` in that script goes to the unix socket of the server
running on the same machine. There is no option that redirects it.

**3. There is no file-based password input.** `grep passwordFile` in that module
returns zero hits. The only way to set a password is `ensureClauses.password`
(**:473**), a literal Nix string. That value is:

- rendered into the `postgresql-setup` unit script at **:109**
  (`psql -tAc ${lib.escapeShellArg alterRoleSQL}`), i.e. into a **world-readable
  `/nix/store` path** on every machine that evaluates the config;
- also passed as a builder argument to the `system.checks` validation derivation
  at **:158**, so it lands in the `.drv` too — and gets copied to any binary
  cache the closure is pushed to;
- quoted for SQL by naive concatenation at **:84**
  (`"${directive} '${v}'"`). A password containing `'` produces malformed SQL or
  a clause injection.

Upstream's own comment at **:472** says as much: *"Generate hashes using
PostgreSQL or a dedicated script rather than storing passwords in plain text."*
The option is designed for a pre-computed SCRAM verifier you are happy to publish,
not for a live credential.

**4. Its whole auth model is peer.** The option documentation states it plainly
(**:493-495**): *"The PostgreSQL users will be identified using peer
authentication. This authenticates the Unix user with the same name only, and
that without the need for a password."* Peer authentication does not exist over
TCP.

So: for a remote server there is nothing to reach for. This module is that thing.

## How it works

One `oneshot` per role, named `pg-role-<role>.service`. Each one:

1. polls `pg_isready` until the server answers or `readyTimeoutSec` expires;
2. `CREATE ROLE` inside a `DO` block that swallows `duplicate_object`, then
   `ALTER ROLE … WITH <clauses>` — applied every run, so role attributes are
   desired state, not a one-time create;
3. `ALTER ROLE … WITH PASSWORD` in a **separate** psql session (see below);
4. `GRANT CONNECT` / `USAGE` / `SELECT` for each read-only target, plus
   `ALTER DEFAULT PRIVILEGES` (see the trap below);
5. any `extraSQL`, keyed by database.

All SQL is generated into `/nix/store` `.sql` files and run with `psql -f`.
Identifiers are always double-quoted *and* checked by an assertion against
`[A-Za-z_][A-Za-z0-9_$]*`, so a config value cannot become SQL.

## Usage

```nix
{
  imports = [ ./modules/postgresql-external-role-reconciler ];

  services.postgresql-external-roles = {
    enable = true;

    host = "db.internal.example.com";   # or 127.0.0.1 through a leader proxy
    port = 5432;
    sslMode = "require";
    superuser = "postgres";
    superuserPasswordFile = config.age.secrets.pg-superuser.path;

    roles.app = {
      passwordFile   = config.age.secrets.db-app.path;
      clauses        = [ "LOGIN" "NOSUPERUSER" "NOCREATEDB" "CONNECTION LIMIT 120" ];
      ownsDatabases  = [ "app" ];
      revokePublicConnect = [ "app" ];
      consumers      = [ "app.service" "app-worker.service" ];
      restartTriggers = [ config.age.secrets.db-app.file ];   # NOTE: .file, not .path
    };

    roles.reader = {
      passwordFile = config.age.secrets.db-reader.path;
      afterRoles   = [ "app" ];
      readOnly = [
        {
          database = "app";
          schemas  = [ "public" ];
          defaultPrivilegesFrom = "app";    # the role that runs the migrations
        }
      ];
      consumers = [ "metabase.service" ];
      restartTriggers = [ config.age.secrets.db-reader.file ];
    };
  };
}
```

### Key options

| Option | Default | Purpose |
| --- | --- | --- |
| `host` / `port` | `127.0.0.1` / `5432` | The server to reconcile. Loopback is normal when a leader proxy or tunnel is in front. |
| `superuser` | `postgres` | Connecting role. Needs CREATEROLE and membership in the roles it grants for. |
| `superuserPasswordFile` | `null` | Loaded as a credential, exported as `PGPASSWORD`. Null for peer/ident/cert auth. |
| `sslMode` | `prefer` | `PGSSLMODE`. See the TLS trap below. |
| `readyTimeoutSec` | `120` | `pg_isready` polling budget before the unit fails. |
| `suppressStatementLogging` | `true` | `SET log_statement='none'` around the password statement. |
| `dynamicUser` / `user` | `true` / `null` | `DynamicUser` is safe here; switch it off for peer auth. |
| `roles.<name>.passwordFile` | `null` | Cleartext password; null = manage grants only. |
| `roles.<name>.clauses` | `LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION` | Re-applied every run. |
| `roles.<name>.readOnly` | `[ ]` | Per-database read-only grants + default privileges. |
| `roles.<name>.consumers` | `[ ]` | Units ordered after this one, and (default) `Requires=` it. |
| `roles.<name>.afterRoles` | `[ ]` | Ordering between roles in this module. |
| `roles.<name>.restartTriggers` | `[ ]` | Re-run on rotation. **Point at the encrypted source file.** |

## Traps

### The ordering trap: `Before=` alone is not enough

The reconciler must run **before every consumer of the credential** — otherwise
on a fresh host the app starts, fails `password authentication failed for user
"app"`, burns its restart budget, and enters `failed` before the role even
exists. `consumers` sets `Before=` on each named unit.

But `Before=` only orders; it does not gate. If the reconcile *fails* (server
unreachable, wrong superuser password), a consumer with only `After=` starts
anyway, against a stale or absent credential. That is the difference between a
loud failure in one unit and a confusing failure in five.

So `consumers` also installs a `Requires=` (via `requiredBy`, which nixpkgs
realises as a `<consumer>.requires/` symlink —
`nixos/lib/systemd-lib.nix:543`, not as text in the unit). A failed reconcile
now fails the consumer with a dependency error naming `pg-role-<role>.service`,
and `journalctl -u pg-role-<role>` has the real reason. Set
`bindConsumers = false` for ordering-only if you genuinely prefer the app to
start with whatever credential it last had.

### The rotation trap: `.file`, not `.path`

`restartTriggers` must reference the **encrypted source** of the secret
(`config.age.secrets.X.file`, the `.age` file in your repo), not the runtime path
(`config.age.secrets.X.path`, `/run/agenix/X`). The runtime path is a constant —
it never changes, so it never triggers anything. Only the source's store path
moves when you rekey.

Get this wrong and the whole thing silently degrades to "applied once, at the
first boot after install". You rotate the secret, the app picks up the new
password from its file, the database still has the old one, and every service
that touches that role starts failing at once — with nothing in the deploy output
to suggest why.

With `restartTriggers` set correctly the sequence on rotation is: rekey → switch
→ `pg-role-<role>.service` restarts (new source path) → `ALTER ROLE … PASSWORD`
→ consumers restart *after* it because of `Before=`. The window in which the
file and the server disagree is the length of one psql round trip.

### The read-only trap: `GRANT SELECT ON ALL TABLES` is a snapshot

This is the failure this module exists to prevent, and it is worth stating
precisely because it looks like it works.

`GRANT SELECT ON ALL TABLES IN SCHEMA public TO reader` grants on the tables that
exist *at that instant*. It says nothing about future tables. Measured on
PostgreSQL 18.4:

```
GRANT SELECT ON ALL TABLES IN SCHEMA public TO reader;   -- t1 exists
  reader> select count(*) from t1;   →  1
  app>    CREATE TABLE t2(i int);
  reader> select count(*) from t2;   →  ERROR: 42501: permission denied for table t2

ALTER DEFAULT PRIVILEGES FOR ROLE app IN SCHEMA public GRANT SELECT ON TABLES TO reader;
  app>    CREATE TABLE t3(i int);
  reader> select count(*) from t3;   →  0        (works)
```

So the reader breaks on the **next migration**, not on deploy — hours or weeks
later, in whatever dashboard or replica-consumer reads that table.

`ALTER DEFAULT PRIVILEGES` is the standing rule, and it is keyed on the
**grantor**: privileges are recorded per (creating role, schema). Naming the
wrong role is the same bug with extra steps:

```
ALTER DEFAULT PRIVILEGES FOR ROLE app …          -- but migrations run as `migrator`
  migrator> CREATE TABLE t4(i int);
  reader>   select count(*) from t4;  →  ERROR: permission denied for table t4
```

That is what `defaultPrivilegesFrom` is for: set it to **the role that creates
the tables** (the migration role / database owner), not to the reader. The module
emits both the snapshot grant (for tables that already exist) and the default
privilege (for everything after).

Note also that grants are per-database objects, so each `readOnly` entry costs a
separate psql connection with `-d <database>`; the cluster-wide statements
(`ALTER DATABASE … OWNER`, `REVOKE CONNECT … FROM PUBLIC`) go through
`maintenanceDatabase`.

### The cleartext traps

**Never on argv.** `/proc/<pid>/cmdline` is world-readable, so any local user can
scrape a password passed as `psql -c "ALTER ROLE … PASSWORD 'x'"` or
`psql -v pw=x`. Instead the password is exported into the unit's environment and
pulled into psql with the `\getenv` meta-command:

```sql
\getenv pgrolepw PG_ROLE_PASSWORD
ALTER ROLE "app" WITH PASSWORD :'pgrolepw';
```

`/proc/<pid>/environ` is `0400` and owned by the process user, unlike `cmdline`.
The `:'var'` form is psql's SQL-literal quoting, which escapes embedded quotes
correctly — verified end-to-end with a password containing `'`, `"` and `$`: the
role is created and authenticates. (Compare upstream's **:84**, which wraps the
value in bare single quotes.)

**Version bound: `\getenv` requires PostgreSQL ≥ 14.** The module asserts on
`package.version` rather than silently producing SQL that older psql treats as an
unknown backslash command.

**Not in the server log either.** `ALTER ROLE … PASSWORD` carries the cleartext,
so on a cluster with `log_statement = 'ddl'` or `'all'` (or a low
`log_min_duration_statement`) it is written to the server log in the clear. The
password session therefore opens with `SET log_statement='none'` and
`SET log_min_duration_statement=-1`. This needs a superuser connection; if you
reconcile with a CREATEROLE-only role, set `suppressStatementLogging = false`
(and accept the log exposure), otherwise the `SET` aborts the unit under
`ON_ERROR_STOP=1`. The statement is still visible in `pg_stat_activity` for its
duration, and `pgaudit` is not covered.

**`LoadCredential`, not "chown the secret to the service user".** systemd reads
the file as PID 1 (root) and drops a `0400` copy in `$CREDENTIALS_DIRECTORY`
owned by the unit's user. Consequences worth having:

- the secret on disk can stay `0400 root:root` — no `owner = "postgres"` on every
  age secret just so a reconciler can read it;
- the reconciler needs no persistent identity, so `DynamicUser = true` is the
  default and the unit gets a fresh uid, `ProtectSystem=strict`, an empty
  `CapabilityBoundingSet` and a `@system-service` syscall filter for free;
- the credential is unmounted when the unit exits.

### The DynamicUser / peer-auth trap

If your "external" server is reached over a **unix socket** with `peer` or
`ident` authentication, the server maps the *unix* user name to a database role.
A `DynamicUser` has a per-activation generated name, so peer auth can never
match. Set `dynamicUser = false; user = "postgres";` for that case. TCP with a
password (the normal remote case) is unaffected.

### The TLS default

`sslMode` defaults to `prefer`, matching libpq. `prefer` silently falls back to
an unencrypted connection if the server does not offer TLS — and this connection
carries a superuser password *and* a role password. For anything off-box set
`require` at minimum, `verify-full` if you have the CA wired up.

## How failure is surfaced

Nothing is skipped quietly:

- `set -euo pipefail` in the script and `-v ON_ERROR_STOP=1` on every psql, so
  the first failing statement fails the unit. There is no `|| true` anywhere.
- Unreachable server → the `pg_isready` loop fails after `readyTimeoutSec` with
  `pg-role: <host>:<port> not accepting connections after 120s` rather than one
  connection error per statement.
- `Type=oneshot` with `Restart=on-failure` and `RestartSec` (30s): `on-failure`
  is permitted on a oneshot — `always` is not — so a host that boots before its
  VPN retries instead of staying broken until the next deploy.
- `RemainAfterExit=true` means `systemctl status pg-role-<role>` reads `active
  (exited)` once applied, so the `Requires=` from consumers is satisfied for the
  rest of the boot rather than re-running per consumer.
- A missing schema or database is a hard error. If you have a database that only
  exists after some other bootstrap, put those statements in `extraSQL` on a role
  whose consumers can tolerate the retry loop, or split it into its own role
  entry — do not paper over it with `|| true`, which is how a grant silently
  stops being applied.

## Test

`test.nix` is a two-node NixOS VM test — one node runs PostgreSQL, the other
runs this module and no PostgreSQL at all. Run it:

```sh
nix-build test.nix --arg pkgs 'import <nixpkgs> { system = "x86_64-linux"; }'
```

or from a flake, `pkgs.callPackage ./modules/postgresql-external-role-reconciler/test.nix { }`.

Nodes are addressed with `lib/nixos-test-topology`, so neither machine carries a
framework-assigned phantom address (the test asserts no `192.168.*` exists
anywhere). What it proves:

| # | claim |
|---|-------|
| 0 | *(eval-time)* a role name that is not a bare SQL identifier is rejected by the assertion; the deployed config is assertion-clean; the generated unit takes the secret through `LoadCredential` and never names the path in its script |
| 1 | the role authenticates from the reconciler host with the password that only ever existed in a `0400 root:root` file — a file `nobody` cannot read and the `DynamicUser` unit never opened; `inet_server_addr()` confirms the server is the remote node |
| 2 | `clauses` landed (`NOSUPERUSER/NOCREATEDB/NOCREATEROLE/NOREPLICATION/LOGIN`) |
| 3 | `revokePublicConnect` removed `CONNECT` from `PUBLIC`; `ownsDatabases` moved the owner |
| 4 | the read-only grant is read-only **both ways**: `SELECT` works, `INSERT`/`UPDATE`/`DELETE`/`CREATE TABLE` each fail on the server's own permission error, and the row is verified unchanged afterwards. `SELECT` on a sequence works, `nextval()` does not |
| 5 | `defaultPrivilegesFrom` covers objects the owner role creates **after** the reconcile, with no re-run |
| 6 | rotation: rewriting the key file alone changes nothing *(control)*, and after a restart the OLD password is refused with `password authentication failed` while the NEW one works and keeps every grant |
| 7 | ordering, causally: with both units stopped and the password drifted out-of-band, the consumer's own probe is shown to fail *(control)*, then starting **only** the consumer succeeds — `Requires=`/`After=` pulled the reconciler in and it repaired the credential first |

Each claim was verified to fail when the module is broken, not merely to pass:

| mutation | observed |
|----------|----------|
| drop the `ALTER DEFAULT PRIVILEGES … GRANT SELECT ON TABLES` emission | subtests 0–4 still pass, **5 fails** |
| apply the password only when `pg_authid.rolpassword IS NULL` (i.e. bootstrap-once instead of reconcile) | subtests 0–5 still pass, **6 fails** on the old password still working |
| drop `before` / `requiredBy` for `consumers` | subtests 0–6 still pass, **7 fails** — `systemctl start <consumer>` itself fails, because nothing repaired the drifted credential |

That last column is the point: a module that is merely a one-shot bootstrap
looks perfect until subtest 6.

## Notes

- **It never deletes.** Like upstream `ensureUsers`, removing a role from the
  config does not drop it; renaming leaves the old role behind. Reconcile means
  "converge what is declared", not "own the whole cluster".
- **Least privilege for the connecting role.** `superuser` needs `CREATEROLE`,
  ownership (or membership) for `ALTER DATABASE … OWNER`, and membership in the
  grantor role for `ALTER DEFAULT PRIVILEGES FOR ROLE`. A true superuser is the
  simplest way to satisfy all three; it is not required if you set those up by
  hand and turn off `suppressStatementLogging`.
- **Stronger option: pre-computed SCRAM verifiers.** PostgreSQL accepts
  `PASSWORD 'SCRAM-SHA-256$4096:…'`, which means the cleartext never leaves the
  host at all. That needs a PBKDF2 implementation on the reconciling side, so
  this module keeps its dependency set to `pkgs.postgresql` and mitigates the
  log/argv exposure instead. If your threat model includes the database's own
  log pipeline, compute the verifier locally and pass it through `extraSQL`.
