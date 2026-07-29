# pgadmin-container-host-socket

Run **pgAdmin** (or any bundled web DB admin) inside a private-network NixOS
container that reaches the **host's** PostgreSQL over a bind-mounted
`/run/postgresql` **Unix socket** — not TCP.

## Problem

pgAdmin ships a whole web stack (Python + a bundled server). Running it
directly on the host drags that stack into the host's network namespace and
tempts you into opening a TCP port on PostgreSQL just so the admin UI can
reach it. You want:

- pgAdmin isolated in its own namespace,
- the DB reachable with **no TCP listener and no password on the wire** for
  local connections,
- a clean reverse-proxy handoff to nginx for TLS.

A NixOS container with `privateNetwork = true` plus a bind-mounted socket
directory gives you all three.

## The load-bearing details (traps)

Four things look redundant but are each doing real work. Remove any one and it
breaks in a way that's annoying to debug:

1. **Bind-mount `/run/postgresql` read-write into the container.** This is the
   whole trick: pgAdmin (and the optional role-setup step) connect to the host
   database over the Unix socket. No TCP, no network exposure.

2. **Pin the container's `services.postgresql.package` to the host's.** The
   container only needs the *client* libraries, but they must match the server
   version, or you get protocol/catalog mismatch errors that look like
   corruption. The module reads `config.services.postgresql.package` from the
   host and forces the same package inside.

3. **`DEFAULT_SERVER = "0.0.0.0"`.** By default pgAdmin binds loopback only.
   Inside the container that means the host-side nginx proxy at
   `localAddress:port` gets **connection-refused**. Binding `0.0.0.0` makes it
   listen on the container's veth so the proxy can reach it.

4. **Order.** The container is `after`/`requires` `postgresql.service` so the
   socket exists before pgAdmin starts (otherwise it comes up unable to connect
   and you must restart it). The container→host firewall is kept minimal: only
   DNS to the host resolver is allowed on the veth (`ve-pgadmin`); the
   host-initiated nginx proxy → pgAdmin traffic is accepted as an established
   connection, so no blanket `trustedInterfaces` entry is needed.

## Usage

Import the module and enable it:

```nix
{
  imports = [ ./modules/pgadmin-container-host-socket ];

  modules.services.pgadmin = {
    enable = true;
    domain = "pgadmin.example.com";        # nginx vhost + ACME cert name
    passwordFile = "/run/secrets/pgadmin-initial-password";
    operatorUser = "alice";                # optional human who may read dataDir
  };
}
```

Provision `passwordFile` with your secrets tooling (sops-nix, agenix, a
systemd credential — anything that lands a file on disk). The module never
writes secrets into the Nix store.

### Creating a DB login role

Set `createUser = true` and provide `pgadminPasswordFile` to have the host run
a one-shot that idempotently creates/updates a `pgadmin` PostgreSQL role
(`CREATEDB` + `CREATEROLE`). It runs as the `postgres` user over the local
socket, waits for `pg_isready`, and is ordered before the container.

```nix
modules.services.pgadmin = {
  enable = true;
  createUser = true;
  pgadminPasswordFile = "/run/secrets/pgadmin-db-password";
  # ...
};
```

The role password is **never placed on the psql command line** (argv is
world-readable via `/proc/<pid>/cmdline` on a default host). The one-shot feeds
all SQL to `psql` over stdin and has psql read the secret itself into a
variable, which also expands as a properly escaped literal to avoid SQL
injection.

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `enableNginx` | `true` | Publish through a local nginx reverse proxy. |
| `domain` | `null` | nginx virtual-host name (required if `enableNginx`). |
| `acmeHost` | `domain` | ACME cert name for TLS; `null` serves plain HTTP. |
| `passwordFile` | `null` | Initial pgAdmin web login password (required). |
| `operatorUser` | `null` | Human account added to the `pgadmin` group to read `dataDir`. |
| `createUser` | `false` | Provision a `pgadmin` login role in the host DB. |
| `pgadminPasswordFile` | `null` | Password for that role (required if `createUser`). |
| `dataDir` | `/var/lib/pgadmin` | Persistent state directory (mode 0700). |
| `port` | `5050` | Port pgAdmin listens on inside the container. |
| `email` | `admin@example.com` | Initial pgAdmin login email. |
| `uid` / `gid` | `5050` | Ownership of `dataDir`. |
| `containerNetwork.hostAddress` | `192.168.202.1` | Host side of the veth pair. |
| `containerNetwork.localAddress` | `192.168.202.2` | Container side of the veth pair. |

## Caveats

- The container reaches the DB **as whatever role local socket auth grants**.
  With the common `peer`/`trust` local setup, the container process can act as
  privileged DB roles — treat the container boundary as part of your DB trust
  model.
- `dataDir` is mode `0700`; only `operatorUser` (if set) and the service user
  can read it.
- If you terminate TLS elsewhere, set `acmeHost = null` (or `enableNginx =
  false`) and point your own proxy at `localAddress:port`.
- The `/run/postgresql` bind mount assumes the host uses the default socket
  directory. Adjust both sides if yours differs.

### Security notes

- **Container→host firewall is intentionally minimal.** The veth allows only
  DNS to the host resolver; pgAdmin is an internet-facing web app with a CVE
  history, so it is deliberately *not* granted blanket access to host-bound
  services. If pgAdmin genuinely needs to reach another host port, add a scoped
  rule under `networking.firewall.interfaces."ve-pgadmin"` rather than trusting
  the whole interface.
- **DB role password is quoted safely.** When `createUser` is set, the one-shot
  has psql read the secret into a variable and expand it via `:'pw'`, which
  escapes it as a SQL string literal — a password containing quotes cannot
  break out or inject DDL. The secret also never appears on any process argv.
