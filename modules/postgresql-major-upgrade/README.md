# postgresql-major-upgrade

A NixOS module that performs a **PostgreSQL major-version upgrade by dump and
restore**, as a systemd unit ordered *before* `postgresql.service`. It works
between any two majors your nixpkgs provides (17 → 18, 15 → 18, …); the old
binaries are selected automatically from the on-disk `PG_VERSION`.

## The problem

On NixOS, `services.postgresql.dataDir` defaults to
`/var/lib/postgresql/$psqlSchema` — a *version-specific* path. Bump
`services.postgresql.package` from 17 to 18 and nothing appears to break:
postgres starts, initialises a brand-new empty cluster under the new path, and
your data is still sitting untouched in the old directory. Applications come up
against an empty database. Nothing failed loudly; you just quietly lost your
data until someone notices.

Pin `dataDir` to a stable path instead and you get the honest failure: postgres
refuses to start, because a 17 cluster is not readable by an 18 server.

Neither is an upgrade. An upgrade needs someone to move the data across, and it
needs to happen **before** anything can connect to a half-migrated cluster.

## What this does

One `oneshot` unit, ordered `before` `postgresql.service` and pulled in by it,
so it runs to completion before anything can talk to the database.

The safety guarantee does not come from that dependency. `postgresql.service`
gets its own `preStart` check that refuses to start whenever `PG_VERSION` does
not match its package. That holds even if this unit is masked, disabled, or
never ran — and because the unit is only `Wants=`, re-running the upgrade by
hand never drags a healthy database offline.

1. **Detect.** Compare `$dataDir/PG_VERSION` against the configured package. If
   they match, or there is no cluster yet, exit immediately. Refuses to run
   "downgrades" where the on-disk cluster is newer than the package.
2. **Back up all data.** Start the *old* server with `listen_addresses=''` and a
   private socket directory — no TCP, and not on the socket path clients use —
   then `pg_dumpall` with the *new* `pg_dumpall` (the supported direction for
   cross-version dumps). The dump is rejected unless it ends with postgres's own
   completion marker, so a truncated dump can never be mistaken for a good one.
   A manifest of databases, extensions and per-database relation counts is
   captured at the same time.
3. **Take the old version down** cleanly (`pg_ctl -m fast`), then *rename* the
   old data directory aside rather than deleting it.
4. **Bring the new version up without connectivity.** `initdb` reusing the old
   cluster's encoding, collation and ctype, then start it — again with no TCP
   and on the private socket.
5. **Restore locally**, with `ON_ERROR_STOP=1`.
6. **Collation.** Refresh each database's recorded collation version. A
   dump/restore rebuilds every index from scratch, so text ordering already
   matches the running glibc; what remains is the stale *version stamp* that
   otherwise produces "collation version mismatch" warnings. `reindex = true`
   additionally runs `reindexdb` as belt-and-braces.
7. **Health, sanity, vacuum.** Relation counts are compared against the
   pre-upgrade manifest and the upgrade aborts on any mismatch; then
   `vacuumdb --all --analyze` so the new cluster starts with fresh statistics.

Finally the migration instance is stopped and the unit exits, leaving
`postgresql.service` to start the new major normally, on its usual socket and
address.

## The extension trap

Before restoring, every extension the old cluster had is checked against
`pg_available_extensions` on the new server, and the upgrade aborts if any is
missing.

This is the failure mode worth knowing about: if the new package is a bare
`pkgs.postgresql_18` while the old cluster used `vector`, `pg_hint_plan` or
similar, the restore dies partway through on `CREATE EXTENSION`, leaving a
half-populated cluster. Checking first turns that into a clean abort with the
old data still intact. Use `.withPackages` for `newPackage`:

```nix
services.postgresql.package = pkgs.postgresql_18.withPackages (p: [
  p.pgvector
  p.pg_hint_plan
]);
```

## Usage

```nix
{
  imports = [ ./vendor/recipes/modules/postgresql-major-upgrade ];

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_18.withPackages (p: [ p.pgvector ]);
    # A STABLE path — not the versioned default, or there is nothing to upgrade.
    dataDir = "/var/lib/pgcluster";
  };

  modules.services.postgresql-major-upgrade.enable = true;
}
```

`dataDir` and `newPackage` default to the `services.postgresql` values, so
normally enabling it is all that is required.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Turn the upgrade unit on. |
| `dataDir` | `services.postgresql.dataDir` | Cluster to upgrade in place. |
| `newPackage` | `services.postgresql.package` | Target package; must carry the old cluster's extensions. |
| `postgresUser` | `"postgres"` | System user owning the cluster. |
| `backupDir` | `/var/backup/postgresql-major-upgrade` | Dump, manifest and per-step logs. |
| `keepOldDataDir` | `true` | Keep the renamed pre-upgrade directory. This is what makes it reversible. |
| `reindex` | `true` | Run `reindexdb` after restore. |
| `vacuum` | `true` | Run `vacuumdb --all --analyze` before handing over. |
| `requireManualStart` | `false` | `false` migrates automatically; `true` waits for you to start the unit. |
| `requiredFreeSpacePercent` | `120` | Refuse to start without room for the dump. |
| `startTimeoutSeconds` / `stopTimeoutSeconds` | `120` / `300` | `pg_ctl` timeouts. |

## Rolling back

Nothing is destroyed. The dump is in `backupDir`, and the original cluster is
`$dataDir.major-<old>-<timestamp>`. To go back, pin the old package again, move
the directory back into place, and remove the new one.

## Downtime and scope

The database is unavailable for the whole dump-and-restore, which scales with
data size — this is not an online upgrade, and it is not `pg_upgrade --link`.
The trade is that it is version-agnostic, it rebuilds every index (so it is
immune to glibc collation changes), and it keeps a portable dump.

It manages a **single local cluster**. It is not aware of replication or of
Patroni-managed clusters, where the upgrade has to be coordinated across members
and the leader; pointing it at one of those is not safe.

## Automatic or manual

`requireManualStart` chooses who triggers the migration. The guard described
above applies either way, so neither mode can start postgres on a mismatched
cluster.

**`false` (default) — automatic.** `postgresql.service` pulls the upgrade in and
waits for it, so bumping the package migrates and comes back up on its own. This
is what you want for an unattended `nixos-rebuild` or a fleet deploy.

**`true` — manual.** The upgrade never runs by itself. After a package bump
postgres refuses to start and says so in its journal:

```
postgresql: cluster at /var/lib/pgcluster is major 17 but this package is 18.
postgresql: refusing to start on a mismatched cluster; data is NOT lost.
postgresql: run: systemctl start postgresql-major-upgrade.service
```

You then run the upgrade, look at the result, and start postgres when you are
satisfied. Use this when you would rather inspect a migrated cluster before
applications reach it.

Re-running the unit is safe in both modes: once `PG_VERSION` matches it exits
immediately as a no-op, and the database keeps serving throughout.
