# tailscale-lan-router

A NixOS module that turns one box into a full LAN router: a bridge over its
physical ports, NAT to the WAN, Kea for DHCP, and Blocky for caching +
ad-blocking DNS — with optional IPv6 (DHCPv6 + radvd RAs). The reason this is
a recipe and not just a config dump is the **`tailscaleExitNode` trap**: if the
router also routes its own traffic through a Tailscale exit node, LAN clients
appear to lose internet while the router itself stays online, and nothing logs
an error.

## What it does

Enable it and the module wires up, end to end:

- a **bridge** (`brlan` by default) over the interfaces you list, holding the
  LAN gateway address;
- **NAT** from the bridge to `wanInterface` via `networking.nat`;
- **Kea DHCPv4** handing out leases from your pool, advertising the router as
  gateway + DNS;
- **Blocky** as the LAN resolver on `:53` (router IP + loopback), with denylist
  blocking, caching/prefetch, and custom `host → IP` mappings;
- optionally, **DHCPv6 + radvd** router advertisements when `lan.v6.enable`.

## The load-bearing trap: exit node + LAN forwarding

This is the whole reason the module exists in this shape.

Say the router runs `tailscale up --exit-node=…` so its *own* traffic tunnels
out through another node. Tailscale installs a policy-routing rule (table 52)
that grabs traffic and sends it out `tailscale0`. That rule catches **forwarded
LAN packets too** — but those packets still carry their original `192.168.x.y`
LAN source address.

The exit node is a WireGuard peer. Its `AllowedIPs` for your router covers only
the router's Tailscale IP (a `100.x` CGNAT address), **not** your `192.168.x/24`
LAN. So a forwarded packet sourced from `192.168.x.y` arrives at the tunnel,
fails the `AllowedIPs` check, and is **dropped silently**. No rejection, no log
line. The failure mode is "the exit node just doesn't work" — but only for LAN
clients; the router itself has connectivity, which sends you debugging the wrong
box.

The fix, gated behind `tailscaleExitNode = true`:

1. **MASQUERADE onto `tailscale0`** — source-NAT LAN traffic to the router's
   Tailscale IP *before* it enters the tunnel, so it now passes `AllowedIPs`.
   The normal WAN masquerade stays in place as a fallback for when Tailscale is
   down.
2. **Open the FORWARD path** for `brlan ↔ tailscale0` (and the return path with
   `conntrack --ctstate RELATED,ESTABLISHED`).
3. **Allow udp/41641** in FORWARD between `brlan` and `tailscale0`, Tailscale's
   WireGuard/direct-connection port, so peers can still establish direct paths
   through the router.

All the iptables lines are written check-then-add (`-C … || -A …`) with matching
delete-on-stop, so they're idempotent and don't pile up across firewall
restarts.

Leave `tailscaleExitNode = false` (the default) if the router just NATs to a
normal WAN uplink — none of the tailscale rules are emitted.

## Usage

Import `default.nix` as a NixOS module:

```nix
{
  imports = [ ./tailscale-lan-router ];

  modules.lan-router = {
    enable        = true;
    wanInterface  = "enp1s0";
    bridge.interfaces = [ "enp2s0" "enp3s0" ];

    lan.v4 = {
      address  = "192.168.100.1";
      subnet   = "192.168.100.0/24";
      dhcpPool = "192.168.100.100 - 192.168.100.200";
    };

    dns = {
      upstreams = [ "1.1.1.1" "8.8.8.8" ];
      blocking.denylists.stevenblack = [
        "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
      ];
      customMappings."nas.lan" = "192.168.100.20";
    };

    # ONLY if this router routes itself through a Tailscale exit node:
    tailscaleExitNode = true;
  };
}
```

### Key options

| Option | Purpose |
| --- | --- |
| `bridge.name` / `bridge.interfaces` | Bridge device name (default `brlan`) and the physical ports to enslave. |
| `wanInterface` | Uplink interface for NAT. |
| `lan.v4.{address,subnet,dhcpPool}` | Gateway IP, CIDR subnet, and Kea pool range. |
| `lan.v4.prefixLength` | Prefix length for the gateway address on the bridge (default `24`). |
| `lan.v6.*` | Enable + address/subnet/pool for IPv6 (adds DHCPv6 + radvd); `lan.v6.prefixLength` defaults to `64`. |
| `dns.upstreams` | Upstream resolvers Blocky forwards to. |
| `dns.blocking.enable` | Master switch for the Blocky denylist block (default `true`). |
| `dns.blocking.denylists` | Named denylists (hosts-file URLs or inline patterns). |
| `dns.customMappings` | Static `hostname → IP` answers. |
| `dns.httpPort` | Blocky HTTP API port; `null` disables it. |
| `tailscaleExitNode` | The fix above. Default `false`. |

## Caveats

- **You must actually configure Tailscale separately.** This module only adds
  the firewall/NAT plumbing; enabling `services.tailscale` and running
  `tailscale up --exit-node=…` (with `--exit-node-allow-lan-access` if you also
  want LAN clients to reach the exit node's own subnet) is on you.
- The tailscale rules assume the interface is named `tailscale0` — the default.
- Blocky binds `:53` on both the router IP and loopback and `services.resolved`
  is turned off, so the router uses Blocky as its own resolver
  (`resolvconf.useLocalResolver = true`). If something else wants `:53`, they
  collide.
- `systemd.services.blocky.stopIfChanged = false` keeps DNS answering across
  rebuilds instead of bouncing the resolver on every unrelated change.
- The `.lan` search domain and the `${bridge.name}.lan → gateway` mapping are
  conveniences; rename them in `dns.customMappings` / the Kea `domain-name`
  option if you use a different internal suffix.

## Security notes

- With `tailscaleExitNode = true`, the two `udp/41641` FORWARD `ACCEPT` rules
  are **interface-scoped** like the neighbouring rules: outbound is matched on
  `-i brlan -o tailscale0`, the direct-path return on
  `-i tailscale0 -o brlan`. The router never forwards Tailscale's WireGuard
  port on any other interface pair, so an unrelated interface (e.g. the WAN)
  gains no forwarding permission from this feature.

## nftables backend

This module works on both `networking.firewall.backend = "iptables"` (the
default) and `"nftables"`. The two backends drive `tailscaleExitNode`'s fix
differently:

- **iptables** (default): `networking.nat.extraCommands`/`extraStopCommands`
  for the MASQUERADE, `networking.firewall.extraCommands`/`extraStopCommands`
  for the FORWARD accepts and the icmpv6 INPUT accept — exactly as described
  above.
- **nftables**: nixpkgs' nftables NAT module (`nat-nftables.nix`) has no
  `extraCommands` escape hatch at all, so the MASQUERADE gets its own small
  nftables table (`networking.nftables.tables."lan-router-tailscale-nat"`)
  instead. The icmpv6 INPUT accept uses the nftables-native
  `networking.firewall.extraInputRules`. The FORWARD accepts are **not**
  translated because they're not needed: neither backend filters the forward
  hook by default (`networking.firewall.filterForward`, nftables-only, stays
  off), so forwarded traffic is already open on both backends and the
  original FORWARD rules were already redundant with that default — adding
  them would require also turning `filterForward` on, which would newly
  restrict *all* of this router's forwarded traffic, a much bigger and
  riskier change this module does not make.

Nothing here needs `services.egressFilter`-style runtime rule population, so
there's no reload-survival concern: the nftables table is plain declarative
config, safe to manage the normal way.
