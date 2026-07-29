# etcd-cluster-over-tailnet

A NixOS module that runs an [etcd](https://etcd.io/) cluster whose **peer and
client traffic rides only a private mesh interface** (Tailscale, WireGuard, or a
private VLAN) and is never exposed on the public firewall. All etcd URLs are
derived from a single topology attrset, and the voting set is kept deliberately
narrow and co-located so a WAN link flap can't cost you quorum.

## The problem

etcd is a Raft-based distributed store — often the DCS backing something like
Patroni's PostgreSQL leader election. Two things make a naive `services.etcd`
setup fragile:

1. **Quorum is latency- and partition-sensitive.** If you spread etcd voters
   across sites connected by a flaky WAN link, a single transatlantic hiccup can
   drop the cluster below quorum or trigger a spurious leader election — exactly
   when you least want it.

2. **etcd URLs are easy to get wrong.** Client/peer/advertise URLs, the
   initial-cluster string, ports, and the cluster token all have to agree across
   every member. Duplicating those literals per host rots quickly.

## The key insight / trap

- **Keep the voting set small and in one low-latency zone.** Machines can
  *consume* etcd (or run Patroni/replicas) without being etcd voters. Only list
  the co-located members in `peers`. A cross-WAN node that never votes can't
  break quorum when its link flaps. This module makes the voting set an explicit
  option so the boundary is obvious and one-line to change.

- **One topology, many derived URLs.** The `peers` attrset (name → private-mesh
  address) is the *entire* topology. `listenClientUrls`, `listenPeerUrls`,
  `advertiseClientUrls`, `initialAdvertisePeerUrls`, and `initialCluster` are all
  computed from it. Adding or removing a voter is a one-line edit, and every
  member computes the identical `initialCluster` list.

- **Mesh-only, per-interface firewall.** The client and peer ports are opened
  with `networking.firewall.interfaces.<iface>.allowedTCPPorts`, i.e. *only* on
  the mesh interface. They stay closed on every public NIC regardless of your
  global firewall policy. Peer traffic is never advertised on a public address.

- **A loopback client URL is added on purpose** so local `etcdctl` works without
  routing over the mesh.

- **`dataDir` must survive reboots.** On impermanence / wiped-root hosts, point
  `dataDir` at a persistent path (e.g. `/persist/etcd`) and persist it — losing
  the raft log forces a re-bootstrap and can break the cluster.

- **`initialClusterState` is the one operational knob** (see below).

## Usage

Import the module and configure it identically on every voter — it only differs
by which host it runs on, and `nodeName` defaults to the hostname:

```nix
{
  imports = [ ./etcd-cluster-over-tailnet ];

  services.etcdMesh = {
    enable = true;
    interface = "tailscale0";           # your private mesh interface
    clusterToken = "my-etcd-cluster";   # same on every member
    dataDir = "/persist/etcd";          # persistent if you wipe root
    peers = {                           # the voting set, mesh addresses
      node-a = "100.100.0.1";
      node-b = "100.100.0.2";
      node-c = "100.100.0.3";
    };
  };
}
```

### Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `nodeName` | `config.networking.hostName` | This member's etcd name; must be a key of `peers` unless `nodeAddress` is set. |
| `peers` | _(required)_ | Voting set: member name → address on the private mesh interface. |
| `nodeAddress` | `null` | Explicit mesh address for a node that is *not* in the bootstrap `peers` set (a member being added with `initialClusterState = "existing"`). `null` looks it up from `peers`. |
| `interface` | `"tailscale0"` | Mesh interface; ports are opened only here. |
| `clientPort` | `2379` | etcd client API port. |
| `peerPort` | `2380` | etcd peer (raft) port. |
| `clusterToken` | `"etcd-cluster"` | Shared initial-cluster-token; identical on all members. |
| `dataDir` | `"/var/lib/etcd"` | Raft log + data dir; make persistent under impermanence. |
| `initialClusterState` | `"new"` | `"new"` for bring-up, `"existing"` to join a live cluster. |

## Bootstrapping vs. adding a member

- **Initial bring-up:** leave `initialClusterState = "new"` on all voters and
  bring them up together.

- **Adding a voter to a running cluster:** flip the new node to
  `initialClusterState = "existing"`, but **only after** registering it on the
  existing members first:

  ```sh
  etcdctl member add node-d --peer-urls=http://100.100.0.4:2380
  ```

  Starting a fresh node with `"new"` against a live cluster, or with
  `"existing"` before the `member add`, makes etcd refuse to join.

  A joining node is deliberately *not* in the static bootstrap `peers` set, so
  it has no address to look up — give it `nodeAddress` explicitly (an assertion
  catches the case where neither `peers` nor `nodeAddress` supplies one).

## Caveats

- Traffic between members is plain HTTP — it relies on the mesh interface for
  confidentiality and authenticity. Don't route it over anything but your
  encrypted mesh (that's the whole point). If you need TLS between members,
  extend the module to set etcd's peer/client cert options.
- **No client auth: every mesh peer is a full read/write admin.** etcd runs with
  no TLS client certs and no RBAC, so the security boundary is exactly "who can
  reach the client/peer ports on the mesh". Any host on the interface can run
  `etcdctl` against the client port with no credentials and rewrite any key —
  including keys that back things like Patroni leader election. On a flat
  Tailscale tailnet every node is authorized equally, so you MUST restrict reach
  with node ACLs (limit which peers can hit these ports). For any multi-tenant or
  low-trust mesh, don't rely on the network alone: enable etcd RBAC and
  peer/client TLS (extend the module to set etcd's cert/auth flags).
- `clusterToken` namespaces the cluster; it is not a cryptographic secret, but
  keep it distinct per cluster so a stray peer can't join the wrong one.
- An odd number of voters (3 or 5) is strongly recommended for quorum math.
