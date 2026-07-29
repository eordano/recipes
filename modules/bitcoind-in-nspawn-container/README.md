# bitcoind-in-nspawn-container

A NixOS module that runs `bitcoind` inside a `privateNetwork` systemd-nspawn
container, with the chain data bind-mounted from the host.

## The problem

`bitcoind` is an internet-facing daemon: it listens for inbound peer
connections and talks to arbitrary nodes on the public network. If it is
compromised you would rather the blast radius stop at the daemon than reach the
rest of the machine. But you also do not want to redo a multi-hundred-GiB chain
sync every time you rebuild the service.

This module reconciles the two: bitcoind lives in an isolated container with its
own network namespace, while its data directory lives on the host and is
bind-mounted in.

## The key insight: same uid/gid on both sides

The chain data is bind-mounted from the host (`dataDir`) into the container at
`/data`. A bind mount shares the *inodes*, including their numeric owner — there
is no uid translation. So the service user must be declared with the **same
uid and gid on the host and inside the container**. If they differ, the files
show up owned by the wrong user (or `nobody`) on one side, and bitcoind either
can't read its own chainstate or silently writes files the host can't manage.

That is why this module declares the service user twice — once on the host, once
in the container config (both keyed on `name`, which also names the container,
the group and the systemd unit) — both pinned to `cfg.uid` / `cfg.gid`. Don't let
NixOS auto-allocate the uid; pin it.

## Making the module flexible: `settings`

The typed options (`network`, `rpc.*`, `uid`/`gid`, `containerNetwork.*`, ...)
only cover the flags this module's author anticipated. For everything else
there is `settings`, an RFC-42-style free-form option (the same pattern
nixpkgs uses for `services.postgresql.settings` / `services.grafana.settings`)
declared as:

```nix
settings = mkOption {
  type = types.submodule {
    freeformType = types.attrsOf (types.oneOf [ types.bool types.int types.str (types.listOf ...) ]);
  };
  default = { };
};
```

Each attribute of `settings` becomes a bitcoind command-line argument:

- `bool` becomes `1`/`0`. **This is a trap**: bitcoind's own CLI parser does
  not understand the words `true`/`false` as booleans at all — passing
  `-blocksonly=true` is a silent no-op-turned-parse-surprise, not a boolean
  `true`. bitcoind's own convention is `1`/`0`, so this module converts for
  you: `settings.blocksonly = true;` renders as `-blocksonly=1`.
- `int` and `str` are stringified as-is.
- a **list** repeats the flag once per element — this is bitcoind's own
  convention for "list" arguments such as `-rpcallowip`, `-connect`,
  `-addnode`, `-whitelist`: `settings.whitelist = [ "10.0.0.0/24" "10.0.0.5" ];`
  renders as `-whitelist=10.0.0.0/24 -whitelist=10.0.0.5`.

### Worked example: a flag the typed options do not cover

Say you want to cap memory use with `-dbcache`, run in block-relay-only mode,
and whitelist a subnet — none of which have a typed option:

```nix
services.bitcoindContainer.settings = {
  dbcache = 4096;
  blocksonly = true;
  whitelist = [ "10.0.0.0/24" ];
};
```

renders as `-dbcache=4096 -blocksonly=1 -whitelist=10.0.0.0/24`, with no fork
of this module required.

### Precedence (explicit, and matches the code)

Args are built in this order: **typed options → `settings` → `extraArgs`**.
bitcoind's argument parser keeps the *last* occurrence of a scalar flag, so:

1. A key in `settings` **overrides** the same key derived from a typed option
   (e.g. `settings.rpcport` wins over `rpc.port` if both are set — don't do
   that, but if you do, `settings` wins).
2. A key in `extraArgs` **overrides** the same key set via `settings` —
   `extraArgs` is kept as the final, untyped escape hatch for backward
   compatibility and for flags that need no `=value` at all.
3. List-style flags (`-rpcallowip`, `-whitelist`, ...) do **not** override
   this way; occurrences from different sources accumulate. Setting both
   `rpc.allowedIPs` and `settings.rpcallowip` adds both sets of addresses
   rather than one replacing the other.

`extraArgs` keeps working exactly as before — it is not deprecated. `settings`
is additive: it exists so an adopter reaches for a plain Nix attribute set
instead of hand-building `-key=value` strings, while `extraArgs` remains for
one-off or valueless flags.

### Why CLI args, not a generated `bitcoin.conf`

This module has never generated a `bitcoin.conf` — it has always assembled a
flat list of `-key=value` CLI arguments (see `bitcoindArgs` in `default.nix`)
and passed them straight to `ExecStart`. `settings` continues that: it is
rendered into the same CLI-arg list, not into a config file. Two reasons:

- **Zero behavior change.** Introducing a config file would mean adding
  `-conf=/path` inside the container, deciding where that file lives relative
  to the `/data` bind mount, and reasoning about read order between a file and
  CLI args. Staying with pure CLI args keeps today's `ExecStart` line — and
  every current consumer's resolved arguments — byte-for-byte unchanged.
- **`bitcoin.conf` has network-section semantics that CLI args do not.**
  A config file lets you scope a setting to `[main]`, `[test]`, or `[regtest]`
  so the same file behaves differently per network. A CLI flag has no such
  section — it always applies regardless of which network `-mainnet`/
  `-testnet`/`-regtest` selects. That's exactly consistent with how this
  module already treats `network` and `rpc.*`: they are global CLI flags, not
  network-scoped. Adding `settings` as CLI args preserves that existing,
  simpler mental model (one flat arg list, no per-network sections) instead of
  introducing a second, section-aware configuration surface next to it. If you
  need genuinely network-scoped settings, that would be a deliberate future
  extension (e.g. a generated `bitcoin.conf` alongside `-conf=`), not something
  `settings` does today.

## Traps this encodes

- **Shutdown timeout.** On stop, bitcoind flushes its UTXO set (the
  `chainstate`) to disk. On a large node this takes minutes. If systemd
  `SIGKILL`s it first you can corrupt the chainstate and be forced into a long
  reindex. The service sets a long `TimeoutStopSec` (`stopTimeoutSec`, default
  300s). Do not shorten it casually.

- **DNS.** `privateNetwork = true` gives the container a fresh network
  namespace with no inherited resolver. Its only route to the outside is the
  host side of the veth pair, so the container's single nameserver is set to
  `containerNetwork.hostAddress`. That means the **host** must be able to
  resolve DNS on that address (a stub resolver like systemd-resolved, or a
  forwarder, listening there). If bitcoind can't resolve DNS seeds it won't find
  peers.

- **W^X hardening.** The service runs with `MemoryDenyWriteExecute = true`. Any
  `extraArgs` that loads a JIT plugin will fault. If you need one, relax the
  hardening.

## Usage

```nix
{
  imports = [ ./modules/bitcoind-in-nspawn-container ];

  services.bitcoindContainer = {
    enable = true;
    dataDir = "/persist/bitcoind";   # put this on persistent storage
    network = "mainnet";

    rpc = {
      enable = true;
      port = 8332;
      # to reach RPC from the host, allow the host-side veth, not just loopback
      allowedIPs = [ "127.0.0.1" "192.168.203.1" ];
    };

    # anything the typed options above don't model — see "Making the module
    # flexible: `settings`" above for the full trap/precedence writeup
    settings = {
      dbcache = 4096;
      blocksonly = true;   # -> -blocksonly=1, NOT -blocksonly=true
    };
  };
}
```

### Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the container on. |
| `name` | `bitcoind` | Base name for the container, the host/container service user + group, and the systemd unit. Change it only to coexist with, or extend, resources under a specific name. |
| `package` | `pkgs.bitcoin` | The bitcoind package to run. |
| `dataDir` | `/var/lib/bitcoind` | Host path bind-mounted to `/data`. |
| `uid` / `gid` | `1320` | Service user identity — identical host + container. |
| `network` | `mainnet` | `mainnet` \| `testnet` \| `regtest`. |
| `rpc.enable` | `false` | Enable the JSON-RPC server. |
| `rpc.port` | `8332` | RPC port (opened in the container firewall). |
| `rpc.allowedIPs` | `[ "127.0.0.1" ]` | `-rpcallowip` entries. |
| `containerNetwork.hostAddress` | `192.168.203.1` | Host side of the veth; also the container's nameserver. |
| `containerNetwork.localAddress` | `192.168.203.2` | Container side of the veth. |
| `stopTimeoutSec` | `300` | `TimeoutStopSec` — long enough to flush chainstate. |
| `settings` | `{ }` | Free-form `-key=value` flags for anything above doesn't cover (see "Making the module flexible" above). |
| `extraArgs` | `[ ]` | Extra bitcoind flags, rendered after `settings` (mind the W^X trap). |

## Caveats

- Reaching RPC from the host means allowing a veth address in both
  `rpc.allowedIPs` and, if you firewall the host, the corresponding path. RPC is
  not exposed outside the host by default.
- RPC is bound explicitly to loopback and the container-side veth
  (`containerNetwork.localAddress`), not to all interfaces. `rpc.allowedIPs` is
  the source-IP filter on top of that. If you widen `allowedIPs` to reach RPC
  over some other interface, remember the socket still only listens on those two
  addresses — add a matching `-rpcbind=<addr>` via `extraArgs`. Never bind RPC to
  a public address; `-rpcallowip` is not a substitute for network isolation.
- The container `system.stateVersion` is pinned at `24.05`; bump it deliberately,
  not incidentally, since it governs stateful defaults inside the container.
- This isolates the *network* and *filesystem*, not the kernel. nspawn shares the
  host kernel; it is not a hypervisor boundary.
