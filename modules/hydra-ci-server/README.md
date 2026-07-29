# hydra-ci-server

Self-host [Hydra](https://nixos.org/hydra) — the Nix-native CI/CD server —
behind nginx, backed by a PostgreSQL database you provision **declaratively**
instead of letting Hydra bootstrap its own.

The module is written against upstream NixOS options only
(`services.hydra`, `services.postgresql`, `services.nginx`), so it drops into
any NixOS host. The reason it exists as a recipe is the set of five
non-obvious traps between "enabled" and "actually works behind a proxy on a DB
you control." Each is annotated inline in `default.nix`.

## The problem

`services.hydra.enable = true` gets you a process, but:

- Hydra runs as **three** system users and expects to own its database.
- Its search needs a Postgres extension that isn't there by default.
- It builds every link and redirect from a header most proxies don't set.
- If you provision the DB yourself, its first-run bootstrap fights you.

Each of those is a silent failure — the service starts, then misbehaves.

## The five traps

### 1. Three-user peer-auth ident map → one DB role

Hydra runs as `hydra`, `hydra-queue-runner`, and `hydra-www` (fixed upstream).
Postgres **peer** auth authenticates by OS user name, so without a mapping only
a role literally named `hydra-queue-runner` could connect. The module installs
a `pg_ident.conf` map so all three — plus `root`, for out-of-band `psql` — auth
as the single `hydra` role, and a matching `pg_hba.conf` line that enables the
map:

```
hydra  hydra               hydra
hydra  hydra-queue-runner  hydra
hydra  hydra-www           hydra
hydra  root                hydra
```

### 2. `pg_trgm` extension

Hydra's job/build search uses trigram indexes. Without `pg_trgm` the schema
initialization fails and Hydra won't run evaluations. Upstream Postgres has no
per-database setup hook, so the module runs `CREATE EXTENSION IF NOT EXISTS
pg_trgm` in a oneshot ordered **before** `hydra-init`.

### 3. `X-Request-Base` header

Hydra composes every absolute URL — redirects, page links, notification
bodies — from the `X-Request-Base` request header, **not** from `Host`. Behind
a reverse proxy that header is absent unless you set it, and links break in
subtle ways (a login redirect lands on `http://127.0.0.1:3000/...`). The nginx
location sets it explicitly to `https://<domain>`.

### 4. `.db-created` sentinel

`hydra-init` bootstraps its own database on first run: it creates the role and
database and applies the schema. But here the role and database are provisioned
declaratively via `ensureDatabases` / `ensureUsers`, so that bootstrap would
try to `CREATE` objects that already exist — and fail. The module's `preStart`
pre-touches the `.db-created` sentinel Hydra checks, so it skips the bootstrap
and goes straight to running against the DB you gave it.

### 5. Import-from-derivation + large `maxOutputSize`

- `allow-import-from-derivation` is passed both to `nix.settings` **and** into
  Hydra's evaluator env (`NIX_CONFIG` via `extraEnv`) — the nix.conf setting
  alone does not reach the evaluator. Needed for jobsets that fetch/generate
  inputs during evaluation. Caveat: IFD evaluations can't be gated by Hydra's
  `--no-build` dry pass, so IFD jobsets must be built, not dry-evaluated.
- `max_output_size` defaults to 8 GiB. Heavy builds (large ML / CUDA closures)
  otherwise trip Hydra's "output limit exceeded"; raise it as needed.

## Usage

```nix
{
  imports = [ ./hydra-ci-server ];

  services.hydra-ci-server = {
    enable = true;
    domain = "hydra.example.com";
    # acmeHost = "example.com";     # reuse an existing cert; else nginx gets its own
    # buildMachinesFile = "/etc/nix/machines";
    # maxOutputSize = 16 * 1024 * 1024 * 1024;
  };
}
```

### Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `domain` | *(required)* | Public host; used for the vhost and `X-Request-Base`. |
| `port` | `3000` | Loopback port nginx proxies to. |
| `stateDir` | `/var/lib/hydra` | Hydra state directory. |
| `dbName` | `hydra` | Postgres database + role (also the ident-map target). |
| `notificationSender` | `hydra@<domain>` | From-address for failure emails. |
| `acmeHost` | `null` | Reuse this ACME cert; if null, nginx requests its own for `domain`. |
| `buildMachinesFile` | `null` | Optional remote-builder list; null = build locally. |
| `maxOutputSize` | `8 GiB` | Per-output size cap before Hydra rejects a build. |
| `allowImportFromDerivation` | `true` | Enable IFD in nix + the Hydra evaluator. |

## Caveats

- **Postgres must be on the same host** — the peer/ident auth is local-socket
  only. For a remote database you'd switch to `scram-sha-256` and drop the
  ident map.
- **Hydra's three user names are fixed by upstream.** Don't rename them; the
  ident map depends on them.
- **`acmeHost = null` requires nginx to be able to complete an ACME challenge**
  (open :80, resolvable DNS). If your certs come from elsewhere, point
  `acmeHost` at the cert you already manage.
- The module sets `nginx.enable` and `postgresql.enable` with `mkDefault`, so
  it coexists with an existing server config but won't fight an explicit
  `= false`.
