# patroni-ha-cluster

An opinionated NixOS module that wraps upstream `services.patroni` for running a
PostgreSQL high-availability cluster whose **etcd voting quorum is pinned to one
region**. It exists to make a specific, easy-to-get-wrong topology safe by
default: a cluster with one or more members far away (another datacenter,
another continent) on a high-latency link.

## The problem

Patroni gives you automatic failover by storing cluster state in a distributed
consensus store (here: etcd). Failover is only as safe as that consensus. Two
failure modes bite people who spread members across a WAN:

1. **Split quorum.** If etcd voting members live in two regions, a network
   partition between them can lose quorum entirely — the whole cluster goes
   read-only or unavailable, even though each side is individually healthy.
2. **Spurious failover.** A brief WAN hiccup makes a distant primary look dead,
   Patroni promotes a replica, and now you have two timelines to reconcile.

## The insight

Keep the **entire voting quorum in a single region**. Members in other regions
still talk to that etcd — but only as *clients*, never as voters — and they are
tagged `nofailover` so they can never be auto-promoted.

Concretely, this module enforces the pattern through three settings:

- **`etcdHosts` lists only the quorum region's etcd nodes.** A remote member
  points at the same list. It reads/writes cluster state as a client; it does
  not participate in the vote. A WAN partition therefore isolates a *client*,
  which cannot affect quorum, rather than a *voter*, which can.
- **`nofailover = true` on every out-of-region member.** Promotion of a distant
  (async, WAN-RTT-behind) replica becomes a deliberate DR action, never
  automatic.
- **`failsafe_mode = true`.** A replica that loses the DCS keeps serving reads
  instead of demoting itself — exactly what you want for a member on the far
  side of a flaky link.

The net effect: a transatlantic (or any WAN) flap **can never lose quorum or
trigger an election**.

## Traps (read before you touch this)

- **`bootstrap.*` applies exactly once, at cluster init.** `ttl`, `loop_wait`,
  `retry_timeout`, `failsafe_mode`, and all the Postgres GUCs under
  `bootstrap.dcs.postgresql.parameters` are written to the DCS the first time
  the cluster comes up. On a **live** cluster, editing this Nix does nothing —
  you must change them with `patronictl edit-config`. The module still declares
  them so a fresh cluster bootstraps correctly and so the intended values are
  documented in one place.
- **`retry_timeout` is deliberately generous (20s).** Patroni's etcd3 client
  divides `retry_timeout` across the configured hosts. With 3 etcd nodes that is
  ~6.7s/host; a tighter 10s could expire a distant member's key during a normal
  WAN hiccup and cause needless churn. Tune it to your etcd count and RTT.
- **Coexistence mode.** By default (`disableSystemPostgresql = true`) Patroni
  owns the only PostgreSQL on the host and uses the stock `/run/postgresql`
  socket dir. If the host **also** runs an unrelated PostgreSQL (an app that
  bundles its own PG on another port), set `disableSystemPostgresql = false`.
  The module then moves **both** Patroni's `unix_socket_directories` GUC **and**
  its systemd `RuntimeDirectory` to `/run/patroni`, so the two instances never
  fight over the same socket directory or its runtime-directory lifecycle.
- **Secrets stay out of the Nix store.** `superuserPasswordFile` and
  `replicationPasswordFile` are loaded as systemd environment files at runtime.
  Wire them to your secret manager (sops-nix, or equivalent); never inline a
  password, which would land world-readable in `/nix/store`.

## Security notes

- **The Patroni REST API (`restApiPort`, default 8008) has no authentication.**
  Upstream Patroni ships it unauthenticated, and it serves not just read-only
  health checks but state-changing endpoints (`/restart`, `/reload`,
  `/switchover`, `/failover`, `/reinitialize` — the last rebuilds a replica's
  PGDATA). With `openFirewall = true` and `firewallInterface = "wg0"`, the port
  is reachable by **every** host on that overlay, not just your DB clients — so
  any node on it (including a compromised low-trust one) can force a failover or
  replica rebuild with an unauthenticated POST. Prefer not opening `restApiPort`
  to a shared overlay: expose it only to the specific router / `patronictl`
  hosts, or set Patroni's `restapi.authentication.username`/`password` (from an
  out-of-store env file) and, ideally, `restapi` TLS, via `extraPgParameters`'
  sibling settings on `services.patroni`.

## Usage

Import `default.nix` as a NixOS module and enable it per host. Topology is plain
options — feed them from whatever inventory you already keep (a flake node list,
terraform output, a hand-written attrset).

```nix
{
  imports = [ ./patroni-ha-cluster ];

  modules.services.patroni-cluster = {
    enable = true;
    scope  = "app-db";

    # This node's advertised address, and the other members'.
    nodeIp        = "10.0.0.11";
    otherNodesIps = [ "10.0.0.12" "10.0.0.13" ];

    # ONLY the quorum region's etcd endpoints — even on a remote member.
    etcdHosts = [ "10.0.0.11:2379" "10.0.0.12:2379" "10.0.0.13:2379" ];

    # Secrets provided out-of-store by your secret manager.
    superuserPasswordFile   = "/run/secrets/pg-superuser";
    replicationPasswordFile = "/run/secrets/pg-replication";

    # Who may connect over the network (localhost is always allowed).
    trustedNetworks = [ "10.0.0.0/24" ];

    # Open the ports only on your overlay/VPN interface.
    openFirewall     = true;
    firewallInterface = "wg0";
  };
}
```

A **remote / DR member** in another region is the same config with two changes:

```nix
  modules.services.patroni-cluster = {
    # ...same scope, same etcdHosts (still the quorum region's etcd)...
    nofailover = true;   # never auto-promote this member
  };
```

Point your application writes at the current primary through a connection router
(HAProxy/pgbouncer/…) that health-checks Patroni's REST API on `restApiPort`,
rather than hardcoding a primary address.

### Key options

| Option | Default | Purpose |
| --- | --- | --- |
| `scope` | `"postgres-cluster"` | Cluster name; identical on all members, unique per DCS. |
| `nodeName` | `config.networking.hostName` | Patroni member name. |
| `nodeIp` | — (required) | Address this node advertises to peers/REST. |
| `otherNodesIps` | `[]` | Advertised addresses of the other members. |
| `etcdHosts` | — (required) | `host:port` of the **quorum region's** etcd only. |
| `nofailover` | `false` | `true` on out-of-region members. |
| `pgPort` / `restApiPort` | `5432` / `8008` | Ports. |
| `disableSystemPostgresql` | `true` | `false` enables coexistence mode. |
| `postgresqlPackage` | `pkgs.postgresql_17` | Must match across members. |
| `postgresqlDataDir` | `/var/lib/patroni/pg` | PGDATA; put on persistent storage. |
| `superuserPasswordFile` / `replicationPasswordFile` | — (required) | Out-of-store secret paths. |
| `superuserUsername` / `replicationUsername` | `postgres` / `replicator` | Role names. |
| `listenAddresses` | `[ nodeIp "127.0.0.1" ]` | PG listen addresses. |
| `trustedNetworks` | `[]` | CIDRs allowed scram over the network. |
| `openFirewall` / `firewallInterface` | `false` / `null` | Port opening, optionally interface-scoped. |
| `extraPgHba` / `extraPgParameters` | `[]` / `{}` | Per-host escape hatches. |

## DR promotion sketch

Because out-of-region members are `nofailover`, promoting one is manual and
intentional — do it only when the quorum region is genuinely gone:

1. Confirm the primary region is down (not just partitioned) — otherwise you
   risk split-brain.
2. On the surviving member, clear its `nofailover` tag and, if the DCS is
   unreachable, follow Patroni's standby-cluster / DCS-recovery procedure to
   establish a new leader.
3. Repoint the connection router at the new primary.
4. When the original region returns, reintroduce its members as replicas
   (`pg_rewind` is enabled) and restore the original `nofailover` topology.

Treat this as a runbook to rehearse, not a config you flip under pressure.

## Requirements

- NixOS with the upstream `services.patroni` module available.
- A running etcd cluster reachable at `etcdHosts`.
- A secret manager providing the two password files out of the Nix store.
- A `patroni` system user/group (created by the upstream module) owning the data
  directory.
