# patroni-leader-proxy

A NixOS module: a local HAProxy that gives PostgreSQL clients a **fixed local
endpoint that always lands on the current Patroni leader**. Failover needs no
client reconfiguration, no DNS change, no restart.

## The problem

You run PostgreSQL in HA with [Patroni](https://patroni.readthedocs.io/). Patroni
elects a leader and, on failure, promotes a replica — but the leader is now a
*different host*. Every write client has to find the new one. Chasing that with
DNS TTLs, floating VIPs, or client-side multi-host connection strings is either
slow, fiddly, or unsupported by your driver.

## The insight

Patroni already exposes a REST API that answers, per node, *"am I the leader?"*:

- `GET /primary` → **200 only on the current leader**, 503 otherwise
- `GET /replica` → **200 only on a running replica**

So point HAProxy in TCP mode at the raw PostgreSQL port of every node, but use
the **REST API as the health check**. The read-write pool then holds exactly one
"healthy" server — the leader — and HAProxy re-points to a newly promoted leader
within `inter × fall` seconds. Clients only ever talk to `127.0.0.1:<port>`; the
proxy quietly follows the leader around the cluster.

An optional read-only pool health-checks `/replica` and round-robins across live
replicas.

```
  client ──▶ 127.0.0.1:5432 (HAProxy, this host)
                 │  TCP-forwards PG port
                 │  health-checks Patroni REST /primary
                 ├─▶ pg1:5432   (/primary → 200  ← leader, gets traffic)
                 ├─▶ pg2:5432   (/primary → 503  ← replica, no traffic)
                 └─▶ pg3:5432   (/primary → 503  ← replica, no traffic)
```

## Usage

```nix
{
  imports = [ ./modules/patroni-leader-proxy ];

  services.patroni-leader-proxy = {
    enable = true;
    nodes = {
      pg1 = "10.0.0.11";
      pg2 = "10.0.0.12";
      pg3 = "10.0.0.13";
    };
    # readPort = 5433;              # optional round-robin replica pool
  };
}
```

Clients connect to `127.0.0.1:5432` for writes (always the leader) and, if you
set `readPort`, `127.0.0.1:5433` for reads (any live replica).

### Key options

| Option | Default | Purpose |
| --- | --- | --- |
| `nodes` | *(required)* | `name -> address` of every Patroni member. |
| `pgPort` | `5432` | PostgreSQL port on each node (forwarded to). |
| `restApiPort` | `8008` | Patroni REST API port (health-checked). |
| `port` | `5432` | Local read-write listen port. |
| `readPort` | `null` | Local read-only (replica round-robin) port; off by default. |
| `bindAddresses` | `[ "127.0.0.1" ]` | Where HAProxy listens (see below). |
| `extraAfterUnits` | `[ ]` | Extra `after=` units, e.g. a VPN (see below). |
| `checkInter` / `checkTimeout` / `checkFall` / `checkRise` | `5s` / `8s` / `5` / `2` | Health-check tuning (see below). |

## Traps and tunings (do not naively "tighten")

### Servers start DOWN, on purpose

HAProxy's default is to consider a health-checked server **UP** until a check
proves otherwise. For a pool whose entire job is "only the leader", that default
is backwards: for up to `checkInter × checkFall` after HAProxy starts — 25
seconds at the defaults here — every node is in the RW pool, and a write can be
round-robined onto a replica.

`default-server init-state down` inverts it: a node joins the pool only after
`checkRise` successful checks say it is the primary. The cost is that the RW
port refuses connections for up to one `checkInter` after a proxy restart. That
is the right trade: a brief, obvious outage beats a silent write to a replica.

This requires HAProxy 3.1 or newer. On older builds HAProxy rejects the unknown
keyword and refuses to start, which is at least a loud failure rather than a
quiet misroute.


**WAN-tolerant timings.** If the proxy health-checks nodes across a high-latency
link (a stretched cross-region cluster), a *healthy* `/primary` check can take
1–2s over a ~150ms RTT. A tight `inter 3s` / `timeout check 3s` flaps the whole
pool DOWN on every jitter spike — dropping all writes for no reason. The defaults
here are `inter 5s fall 5 rise 2` (≈25s to mark a node down) with
`timeout check 8s`. Raise them further for slower links; do not lower them
because the LAN case "looks fine".

**Live connections survive blips.** HAProxy's `on-marked-down shutdown-sessions`
is deliberately **not** set. On a transient health-check failure you want
existing PostgreSQL connections to survive, not be killed and re-pooled. (The
leader itself hasn't moved — only a check timed out.)

**Boot ordering when checks ride a VPN.** If the Patroni nodes are reachable only
over an overlay network (Tailscale, WireGuard, ...), HAProxy starting before that
interface is up trips every server to "No route to host" and leaves the RW pool
empty for ~30s until checks recover. Pass the overlay's unit via
`extraAfterUnits = [ "tailscaled.service" ];` (or your WireGuard unit).
`network-online.target` is always ordered before HAProxy.

**Log-noise suppression.** `option dontlog-normal` drops the clean-termination
line every PostgreSQL connection emits. On a busy host this is tens of thousands
of lines per boot that otherwise drown the DOWN/UP/retry events you actually care
about.

## Binding for containers / VMs

`bindAddresses` defaults to loopback, for host-local consumers. To let containers
or microvms on the same host reach the proxy, add the bridge / VM gateway IP:

```nix
services.patroni-leader-proxy.bindAddresses = [ "127.0.0.1" "172.20.0.1" ];
```

If that bridge IP may not exist yet when HAProxy starts, allow non-local binds:

```nix
boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;
```

## Notes

- This is the **write-path companion** to your Patroni setup — Patroni elects the
  leader; this module finds it. It does not manage PostgreSQL or Patroni itself.
- Running the proxy *on the same host* as a Patroni member is fine — just set
  `port` to something other than 5432 (e.g. `15432`) so it doesn't collide with
  the local PostgreSQL.
- A Patroni member tagged `nofailover` still answers `/replica` while it streams,
  so it will appear in a `readPort` pool. Exclude it from `nodes` if you don't
  want reads routed there.
