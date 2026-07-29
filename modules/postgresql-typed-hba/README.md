# postgresql-typed-hba

A NixOS module that wraps the upstream `services.postgresql` with **typed,
named `pg_hba.conf` / ident rules**, function-based extensions, and a
**post-init SQL oneshot ordered before `postgresql.target`** — so anything that
waits on the target sees a fully provisioned database instead of racing an empty
one.

## The problem

`services.postgresql.authentication` and `.identMap` are free-form strings: you
hand PostgreSQL a blob of `pg_hba.conf` text and hope the columns line up. That
makes rules hard to compose across modules, easy to get wrong (a `local` rule
must *not* have an address column; a `host` rule *must*), and impossible to
override a single default without restating the whole file.

Worse, the well-known ordering trap: `services.postgresql` marks itself ready as
soon as the server accepts connections, but your `initialScript` grants and
`CREATE EXTENSION` statements haven't necessarily all landed. A consumer service
with `after = [ "postgresql.service" ]` can start, connect, and find the
extension or grant it depends on **doesn't exist yet**.

## What it does

### Typed, named auth + ident rules — with `null` to drop a default

`authRules` is an attrset of *named* submodule rules (typed `type` / `database`
/ `user` / `address` / `method` / `options`), not a string. The final
`pg_hba.conf` is emitted in **sorted-name order** — which matters because
pg_hba is first-match-wins, so the name is your ordering key (hence prefixes like
`45-…` / `50-…`).

Three defaults ship so a local `root` can reach the `postgres` superuser via
peer auth + a `superuser_map` ident mapping. To remove a default, set its entry
to **`null`**; to change one, redefine it by name. Assertions catch the classic
mistakes at build time (address on a `local` rule, missing address on a `host`
rule).

### `enableTCPIP` flips on automatically

If *any* rule is host-based (`host`, `hostssl`, …), the module turns
`enableTCPIP` on for you via `mkDefault`, and a backstop assertion fails the
build if something forced it off. No more "I added a `host` rule but PostgreSQL
still only listens on the socket."

### Post-init SQL runs before `postgresql.target`

`setupStatements.postInit` (global) and `setupStatements.perDatabase` (keyed by
db) run from a `postgresql-custom-setup` oneshot that is:

- `after` + `requires` `postgresql-setup.service` (users/databases exist), and
- `before` + `requiredBy` `postgresql.target`.

So the target is not considered reached until your grants and extensions are in
place. **Order your consumers on `postgresql.target`, not `postgresql.service`,**
and the race disappears. `setupStatements.initial` still feeds the normal
`initialScript` for statements that must run during first-boot setup.

## Usage

```nix
{
  imports = [ ./modules/postgresql-typed-hba ];

  modules.services.postgresql = {
    enable = true;

    # Pick the package version yourself — see the caveat below.
    # e.g. services.postgresql.package = pkgs.postgresql_16;

    extensions = ps: with ps; [ pgvector postgis ];

    # Add a rule; drop a shipped default by setting it to null.
    authRules = {
      "60-app-host" = {
        type = "host";
        database = "appdb";
        user = "app";
        address = "127.0.0.1/32";   # required for host rules; forbidden on local
        method = "scram-sha-256";
      };
      "50-local-postgres" = null;   # remove a default by name
    };

    setupStatements.perDatabase.appdb = [
      "CREATE EXTENSION IF NOT EXISTS vector"
      "GRANT ALL ON SCHEMA public TO app"
    ];
  };

  # Consumers should wait on the TARGET so they see the provisioned DB:
  systemd.services.myapp.after = [ "postgresql.target" ];
}
```

Optional Prometheus exporter:

```nix
modules.services.postgresql.enableExporter = true;   # exporterPort defaults to 9187
```

**Security note on the exporter.** It connects as the `postgres` **superuser**
(`runAsLocalSuperUser = true`) rather than a scoped `pg_monitor` role, and the
`/metrics` endpoint is **unauthenticated** and exposes detailed DB internals. It
binds loopback (`127.0.0.1`) by default and no firewall port is opened, so it is
not reachable off-box out of the box. Override `exporterListenAddress` /
`exporterDataSourceName` (e.g. a dedicated read-only monitoring role) and only
expose the port behind a firewall or auth proxy.

## Caveats

- **Set `services.postgresql.package` explicitly.** Upstream types that option
  as `package` (never null) and defaults it from `system.stateVersion`, so a
  "is it non-null?" check can never fire — the module used to ship exactly that
  dead assertion and it has been removed. What replaces it is
  `requirePinnedPackage` (default `false`): when set, the module asserts that
  the option carries a definition stronger than upstream's `mkDefault`, i.e.
  that *you* chose the version. Turn it on if you want a major-version bump to
  be impossible as a side effect of moving `stateVersion`.
- `authentication` and `identMap` are emitted with `mkForce`; this module owns
  those strings. Compose through `authRules` / `identMap`, not by also setting
  `services.postgresql.authentication` elsewhere.
- The default ident map includes `/^(.*)$ -> \1` (system user maps to same-named
  PG role). Keep or drop it deliberately depending on how permissive you want
  peer/ident auth to be.
- `perDatabase` statements run against an existing database; create the database
  itself through `services.postgresql.ensureDatabases` (or `initial`).
- `extensions` is **not** empty by default — it is `ps: with ps; [ pgvector ]`.
  Override it if you don't want pgvector built into the server.
