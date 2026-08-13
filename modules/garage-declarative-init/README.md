# garage-declarative-init

A NixOS module that wraps upstream `services.garage` so a
[Garage](https://garagehq.deuxfleurs.fr) S3-compatible object store is **fully
declared in Nix** -- cluster layout, buckets, and access keys -- and reconciled
**idempotently on every boot**, instead of the imperative one-time CLI steps
upstream leaves you with.

## The problem

`services.garage` gets you a running daemon, but a fresh Garage cluster is inert
until you run a sequence of `garage layout assign` / `garage layout apply`
commands by hand, then `garage bucket create`, `garage key import`, and
`garage bucket allow` for every bucket and key. Those are one-shot imperative
steps that live nowhere in your config. Rebuild the host, restore it, or hand it
to a colleague and the knowledge of "what buckets/keys exist and how the layout
was committed" is gone.

This module moves all of that into declarative options and a boot-time
reconciler, so the object store's shape is version-controlled and reproducible.

## What it does

- **State-driven layout init.** A `garage-init` oneshot runs on every boot and
  inspects `garage layout show`, then does the right thing:
  - fresh cluster (no roles), single-node -> assign this node a role and commit;
  - fresh cluster (no roles), multi-node -> **do nothing** (see below);
  - staged-but-uncommitted changes -> commit them;
  - existing cluster this node hasn't joined -> assign self and commit, unless
    `assignLayoutRole = false`;
  - already configured -> do nothing.
  Layout version numbers are read from the live state and incremented, so
  applies are safe to re-run.

  The multi-node case is deliberately inert, and this is the third trap worth
  stating outright: an empty layout does **not** mean the cluster is fresh. It
  is also exactly what a cluster member sees before it has met its peers. A
  node that self-assigns there forks a *second* single-node cluster carrying
  its own ID, and that fork can never be applied anyway, because one node
  cannot satisfy a replication factor above 1. Worse, the orphan role sticks
  around in the layout under a node ID nobody will ever see again. Bootstrapping
  a genuinely new multi-node cluster is a deliberate operator action, not
  something a boot-time reconciler should attempt.
- **Declarative buckets** via `ensureBuckets` -- created if missing, skipped if
  present.
- **Declarative access keys** via `ensureAccess` -- access/secret key material is
  read from files (so it can come from your secret manager), imported by ID
  (existing keys are detected and not re-imported), and granted the requested
  permissions on a bucket.
- **Public exposure** (optional) through nginx vhosts, not the firewall.

## The traps this encodes

Two ordering/identity gotchas are the real value here, both easy to get wrong:

1. **`DynamicUser` must be forced off on a persistent data mount.** Upstream's
   garage unit runs with `DynamicUser`, which allocates a *fresh uid per
   activation*. On a persistent data directory that means the next generation
   can no longer map the on-disk file ownership -- the daemon ends up unable to
   read its own state. This module sets `DynamicUser = lib.mkForce false` and
   pins a stable system user.

2. **The daemon must wait for its data mount.** If `dataDir` sits on a
   late-mounted filesystem (ZFS dataset, NFS, LUKS), the daemon can start before
   the mount is up, create/populate the directory on the *underlying* filesystem,
   and then get shadowed once the real mount appears. A `garage-setup-dirs`
   oneshot orders after the mount unit(s) you pass in `requiresMounts`, creates
   and chowns the dirs, and runs `before` the daemon. List your mount unit there
   and the whole chain waits correctly.

Metadata is placed in a `meta` sibling of `dataDir` and both are created with
`0700` ownership by the configured user.

## Exposure model

Only the **RPC** and **admin** ports are ever opened on the firewall, and only
on the interface you name in `trustedInterface` (e.g. a VPN/WireGuard/Tailscale
interface). The **S3 API** and **web** ports are never firewalled open -- they
reach the outside world solely through the nginx vhosts
(`s3.garage.<domain>`, `*.web.garage.<domain>`), which require an ACME cert for
`<domain>`. Set `exposeNginx = false` for an internal-only node (e.g. a
replication-only cluster member).

## Usage

Import `default.nix` as a module and configure it. Minimal single-node:

```nix
{
  imports = [ ./garage-declarative-init ];

  services.garage-manager = {
    enable = true;

    # Point these at your secret manager (agenix, sops-nix, deploy files, ...).
    rpcSecretFile  = "/run/secrets/garage/rpc-secret";
    adminTokenFile = "/run/secrets/garage/admin-token";

    dataDir  = "/var/lib/garage/data";
    capacity = "100G";

    ensureBuckets = [ "backups" "media" ];

    ensureAccess = [
      {
        key           = "app-backup";
        bucket        = "backups";
        accessKeyFile = "/run/secrets/garage-backup-access-key";
        secretKeyFile = "/run/secrets/garage-backup-secret-key";
        permissions   = [ "read" "write" ];
      }
    ];

    # Publish public endpoints (needs an ACME cert for the domain).
    exposeNginx = true;
    domain      = "example.com";
  };
}
```

Data on a ZFS dataset (or any late-mounted filesystem):

```nix
services.garage-manager = {
  enable        = true;
  dataDir       = "/mnt/pool/garage/data";
  requiresMounts = [ "mnt-pool.mount" ];       # your dataset's systemd mount unit
  # ...
};
```

Multi-node cluster member:

```nix
services.garage-manager = {
  enable            = true;
  replicationFactor = 3;
  nodeAddress       = "10.0.0.5";              # this node's RPC-reachable address
  bootstrapPeers    = [                        # <node_id>@<host>:<port> -- the id is mandatory
    "32be70e860ea7635bf38cd7b71fab97a92f69da1fa81edba4ead2c504b281c1d@10.0.0.6:3901"
    "4c2936c7446a9f6cc2e1772ce9df2161cc7b09bb8dc73fa867f70f76356d7674@10.0.0.7:3901"
  ];
  zone              = "rack-a";
  trustedInterface  = "wg0";                   # RPC + admin opened here only
  # ...
};
```

### Getting the node IDs

A peer entry without its `<node_id>@` prefix is rejected: Garage logs
`Unable to parse and/or resolve peer hostname <addr>` and bootstraps from
nothing. The failure is quiet, because a node that has already met its peers
reconnects from the persisted `<metadata_dir>/peer_list` and never needs
bootstrap again -- so a cluster configured this way keeps working until a node
joins for the first time or loses its metadata, and only then refuses to form.

A node's ID is the public half of the RPC keypair generated in its metadata
directory the first time it starts, so it exists only after that first start
and cannot be computed in advance. Read it off each node with:

```console
$ garage node id -q
32be70e860ea7635bf38cd7b71fab97a92f69da1fa81edba4ead2c504b281c1d@10.0.0.6:3901
```

It is not a secret, and it stays the same for the life of that metadata
directory -- re-creating the directory mints a new ID, which then has to be
updated everywhere it is listed.

To bring up a cluster whose members cannot yet see each other, or to add a node
to a running one without a redeploy, connect once by hand -- the link is
bidirectional and both ends persist it:

```console
$ garage node connect <peer_id>@<peer_host>:3901
Success.
```

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `package` | `pkgs.garage` | Garage package. The init script parses CLI output -- pin a matching version (developed against v2, e.g. `pkgs.garage_2`). |
| `user` / `group` | `"garage"` | System user/group the daemon runs as (kept stable on-disk). |
| `dataDir` | `/var/lib/garage/data` | Data directory; metadata goes in a `meta` sibling. |
| `requiresMounts` | `[ ]` | Systemd `.mount` units the dirs/daemon must wait for. |
| `domain` | `example.com` | Base domain for the nginx vhosts (only if `exposeNginx`). |
| `replicationFactor` | `1` | `> 1` enables multi-node mode. |
| `nodeAddress` | `null` | This node's RPC address; **required** when multi-node. |
| `bootstrapPeers` | `[ ]` | Peer nodes as `<node_id>@<host>:<port>` (multi-node). The id prefix is mandatory -- see above. |
| `zone` | hostname | Garage layout zone for replica placement. |
| `capacity` | `"1G"` | Capacity this node advertises to the layout. **Set this on every multi-node member** -- a zone's usable size is bounded by what its members advertise, so one node left at the default caps its whole zone at 1G. |
| `assignLayoutRole` | `true` | Whether this node may add itself to the layout at `capacity`. Set `false` for a member that should join and gossip but store no replicas. |
| `rpcSecretFile` | -- | File with the shared 32-byte hex RPC secret. Same value on all nodes. |
| `adminTokenFile` | -- | File with the admin API bearer token. |
| `ports.{rpc,s3Api,s3Web,admin}` | `3901/3900/3902/3903` | Port configuration. |
| `trustedInterface` | `null` | Interface on which RPC + admin ports are opened. |
| `ensureBuckets` | `[ ]` | Buckets to create idempotently. |
| `ensureAccess` | `[ ]` | Access keys (from files) + bucket grants to reconcile. |
| `logLevel` | `"warn"` | Garage log level. |
| `exposeNginx` | `false` | Publish public S3 + web vhosts (needs ACME cert). |

## Caveats

- The init script parses the text output of `garage layout show` / `garage
  status`. It was developed against Garage **v2**; a different major version may
  change that output and break the parsing -- pin `package` accordingly.
- `rpcSecretFile` / `adminTokenFile` / the per-key files must be readable by the
  configured user at the time the units run. If you use a secret manager whose
  units come up late, order `garage-init` after it.
- The reconciler assigns/commits layout but does not *remove* buckets, keys, or
  grants you delete from your config -- it converges toward "these exist", not a
  full teardown of anything else.
