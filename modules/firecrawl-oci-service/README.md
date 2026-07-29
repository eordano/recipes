# firecrawl-oci-service

Self-host [Firecrawl](https://github.com/firecrawl/firecrawl) on NixOS from OCI
images — api + worker + headless-Chromium, with a dedicated Redis and an
optional Postgres "NuQ" job queue seeded from a systemd one-shot.

## What it solves

Firecrawl ships as prebuilt container images with **no database migrations** —
the worker assumes its schema already exists. Upstream's happy path is a
`docker-compose` stack of throwaway containers, including a dedicated
`nuq-postgres`. If you instead want to run it declaratively on NixOS, pointed at
**an existing shared Postgres**, and (optionally) deploy the images **offline
from tarballs** rather than pulling from a registry, you hit a handful of
ordering and networking traps. This module encodes the fixes.

## The traps (the reason this exists)

### 1. Seed the queue schema on `postgresql.target`, not `postgresql.service`

The newer Firecrawl moves its job queue off Redis onto Postgres ("NuQ", schema
`nuq`, needs `pgcrypto` + `pg_cron`). The image contains no migrations, so you
must install the schema yourself before the api/worker start.

The one-shot that runs the SQL must order **after `postgresql.target`**.
`postgresql.target` gates on `postgresql-setup.service`, which is what runs
`ensureDatabases`/`ensureUsers`. Plain `postgresql.service` reaches `active`
*before the database exists* — order against it and your `psql` races an empty
cluster and fails. The api and worker units then `requires` + `after` the
one-shot, so they can never start on a half-built schema.

### 2. Keep the seed SQL idempotent — it re-runs every boot

The one-shot is `RemainAfterExit` but still executes on every boot/redeploy, so
`firecrawl-nuq.sql` is written to be safe to replay:

- every object is `CREATE ... IF NOT EXISTS`; enum types are wrapped in
  `duplicate_object` exception guards;
- `pg_cron` jobs are swept with `cron.unschedule(...)` before being
  re-scheduled, so it works on pre-1.6 pg_cron (which errors on a duplicate
  jobname instead of upserting);
- upstream's cluster-wide `ALTER SYSTEM SET ...` tuning is **dropped**, because
  the target Postgres may be shared with other tenants.

### 3. Bind Redis to the bridge gateway (not loopback-only, not all interfaces)

The containers talk to the host's Redis across the OCI bridge, and a container
cannot reach a loopback-only Redis on the host. Instead of exposing Redis on
*all* interfaces, `redisBind` restricts the listener to loopback **plus the
bridge gateway address** the containers dial (`172.17.0.1` for the default
docker bridge, matching `redisUrl`). The gateway entry carries Redis's `-`
prefix so a missing bridge interface is skipped rather than fatal, and the
Redis unit is ordered after `docker.service` so the bridge exists by the time
Redis binds. If you change the bridge subnet or use Podman, adjust `redisBind`
and `redisUrl` together.

### 4. Grant the app role access to the `nuq` schema

The init runs as the `postgres` superuser and *owns* the schema. The containers
connect as a **separate** role, which by default has no rights on `nuq` and hits
`permission denied for schema nuq` (42501). The SQL therefore grants USAGE + ALL
(plus `ALTER DEFAULT PRIVILEGES` for future tables) to the app role — passed in
as the psql variable `dbrole`, wired from the `databaseUser` option.

## Usage

```nix
{
  imports = [ ./modules/firecrawl-oci-service ];

  modules.services.firecrawl = {
    enable = true;
    domain = "firecrawl.example.com";   # optional nginx vhost
    acmeHost = "example.com";           # required when domain is set

    # Offline tarball deploy (leave *ImageFile null to pull from a registry):
    images.apiImageFile = ./images/firecrawl.tar;
    images.playwrightImageFile = ./images/playwright-service.tar;
    images.api = "firecrawl/firecrawl:latest";          # tag inside the tarball
    images.playwright = "firecrawl/playwright-service:latest";

    # Postgres NuQ queue on this host:
    initSchema = true;
    databaseName = "firecrawl";
    databaseUser = "firecrawl";
  };

  # When initSchema is on, you provide the Postgres yourself:
  services.postgresql = {
    enable = true;
    ensureDatabases = [ "firecrawl" ];
    ensureUsers = [
      { name = "firecrawl"; ensureDBOwnership = true; }
    ];
    settings.shared_preload_libraries = [ "pg_cron" ];
    # pg_cron only runs jobs against its configured database:
    settings."cron.database_name" = "firecrawl";
  };
}
```

`firecrawl-nuq.sql` ships in this directory and **must stay alongside**
`default.nix` — the module references it with a relative path (`./firecrawl-nuq.sql`).

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the stack on. |
| `domain` | `null` | Public name for the nginx vhost; `null` = no vhost. |
| `acmeHost` | `null` | `security.acme.certs` entry for TLS; required with `domain`. |
| `listenAddress` | `127.0.0.1` | Host address the API port is published on; loopback so only nginx/the host reaches it. Set to `0.0.0.0` only with auth on. |
| `openFirewall` | `false` | Open port 3002 in the firewall. Off by default — reach the API via the nginx+TLS vhost. |
| `dataDir` | `/var/lib/firecrawl` | Data directory (owned by `user`). |
| `user` / `group` | `firecrawl` | System account that owns data and joins the `redis` group. |
| `uid` / `gid` | `null` | Optional fixed ids; `null` lets NixOS allocate. |
| `images.api` / `images.playwright` | upstream tags | Image references (or the tags inside the tarballs). |
| `images.apiImageFile` / `images.playwrightImageFile` | `null` | Optional `docker save` tarballs for offline deploys. |
| `redisBind` | `127.0.0.1 -172.17.0.1` | Redis bind list: loopback + docker bridge gateway only (never all interfaces). Keep in sync with `redisUrl`. |
| `redisUrl` | `redis://172.17.0.1:6379` | Redis URL as seen **from inside a container** (bridge gateway). |
| `numWorkersPerQueue` | `8` | `NUM_WORKERS_PER_QUEUE`. |
| `useDbAuthentication` | `false` | `USE_DB_AUTHENTICATION`; `false` allows keyless requests (intranet only). |
| `initSchema` | `false` | Seed the NuQ schema into the host's Postgres. |
| `databaseName` | `firecrawl` | Database holding the `nuq` schema. |
| `databaseUser` | `firecrawl` | Role the containers connect as; granted access to `nuq`. |

## Caveats

- `backend` defaults to `mkDefault "docker"`; you can flip the whole stack to
  Podman via `virtualisation.oci-containers.backend`. If you do, revisit
  `redisUrl` **and** `redisBind` — the Podman bridge gateway differs from
  docker's `172.17.0.1`, and the `docker.service` ordering for the Redis unit
  only applies to the docker backend.
- **Exposure is off by default.** The API port (3002) is published on
  `127.0.0.1` only and the firewall is **not** opened, so out of the box the
  stack is reachable solely through the nginx+TLS vhost (or from the host).
  Firecrawl fetches arbitrary caller-supplied URLs, so an unauthenticated,
  network-reachable instance is a full SSRF primitive (e.g. it will fetch cloud
  metadata endpoints or internal services on request). Before flipping
  `listenAddress = "0.0.0.0"` or `openFirewall = true`, set
  `useDbAuthentication = true` and understand you are exposing an arbitrary-URL
  fetcher. Note that `listenAddress` governs the playwright container's port
  3000 as well, so widening it publishes the headless-Chromium service too;
  `openFirewall` only ever opens 3002.
- `useDbAuthentication = false` means anyone who can reach the API can use it.
  Only expose it on a trusted network, or turn authentication on.
- **Redis is unauthenticated and reachable across the OCI bridge.** The listener
  is restricted to loopback + the bridge gateway (`redisBind`, see trap 3), so
  unlike an all-interfaces bind it is never reachable from the LAN/internet even
  if the firewall is misconfigured (6379 is not opened either way). But there is
  no `requirePass`, so any *other* container co-located on the same docker/Podman
  bridge can still read and write Firecrawl's queue and rate-limit keys (job
  injection, DoS, data disclosure). Only run this on a single-tenant container
  host; if you share the bridge with untrusted containers, set a `requirePass`
  on `services.redis.servers.firecrawl` (from a secret file) and fold the
  password into `redisUrl`, or move Redis onto its own network.
- The worker image is the **same** image as the api; the sole difference is
  `FLY_PROCESS_GROUP=worker`. Don't "fix" that by looking for a separate worker
  image — there isn't one.
- The vendored SQL is pinned to a specific upstream `nuq.sql` revision. When you
  bump the Firecrawl images, re-check upstream's schema and update the SQL to
  match; the `ALTER DEFAULT PRIVILEGES` grants keep newly added tables reachable
  without a manual re-grant.
