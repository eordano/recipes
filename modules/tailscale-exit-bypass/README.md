# tailscale-exit-bypass

A NixOS module that selectively diverts *chosen* egress off a Tailscale exit
node and back onto the host's own WAN — per destination CIDR, and optionally
per destination port.

## The problem

When a host is configured to route all its traffic through a Tailscale exit
node, *everything* leaves via the tailnet — including traffic that must not.
The classic case is an outer tunnel: a VPN client (WireGuard, etc.) running on
the host, or inside a local VM, whose outer UDP packets need to reach the
Internet directly. Double-encapsulating that tunnel through the exit node is at
best wasteful and at worst broken.

You want a scalpel: "traffic to *these* destinations (optionally on *this*
port) leaves via my real WAN; everything else keeps using the exit node."

## Why it's harder than one `ip rule`

The naive approach — mark the packets in an `output` chain and add a policy
routing rule — silently fails for exactly the sockets you care about. There are
three traps:

1. **`type route hook output`, not a plain `output` chain.**
   Marking a packet does not, by itself, make the kernel re-run the route
   lookup. Sockets that `connect()` early and cache their destination route
   (QEMU/SLIRP user-mode networking and many UDP sockets do this) never see the
   route the new mark selects — they keep the cached one, still pointing at the
   exit node. The nftables `route` hook forces a route re-lookup *after* the
   mark is set, so those cached-dest sockets actually get diverted.

2. **MASQUERADE on the marked flow is mandatory, not optional.**
   Those same early-`connect()` sockets also cache their *source* address —
   chosen while the route still pointed at the tailscale interface, so it's a
   tailnet / CGNAT (RFC 6598 shared address space) address. After the mark
   flips egress to WAN,
   the packets would leave with that now-wrong tailnet source and the replies
   get dropped as bogons. A `MASQUERADE` (srcnat) on the marked flow rewrites
   the source to the outgoing WAN interface address.

3. **ip rule priority must sit *below* Tailscale's window.**
   Tailscale installs its own policy rules in roughly the 5210–5290 priority
   range. The bypass rule must be consulted *first*, so its priority has to be
   numerically lower (checked earlier). It points at the **`main`** table, which
   still holds the real WAN default — because Tailscale's exit default route
   lives in a *separate* table (commonly table 52), never in `main`.

Get any one of these wrong and the bypass appears installed but doesn't take
effect (or takes effect and then black-holes the replies).

## What the module installs, per named route

- An nft table `inet tailscale-exit-bypass-<name>` with:
  - a `type route hook output priority mangle` chain that matches
    `<optional dport> ip daddr @bypass_targets` and stamps the route's fwmark;
  - a `type nat hook postrouting priority srcnat` chain that MASQUERADEs the
    marked flow.
- An `ip -4 rule add fwmark <mark> lookup main priority <prio>`.
- A oneshot systemd service that resolves the destination set and applies the
  rules atomically (reload is idempotent).
- A timer that re-asserts every `reassertSeconds` (60s default), so the bypass
  survives `tailscale up` re-runs, transient config-fetch failures, and manual
  `ip rule` fiddling. Apply short-circuits on an unchanged hash of
  `cidrs + fwmark + rule`, so steady-state cost is a few syscalls per tick.
- An optional probe service/timer that runs
  `ip route get <sample> mark <fwmark>` and reports `degraded` (to a JSON file
  under `/run/tailscale-exit-bypass/`) if the egress device still matches the
  forbidden pattern (default `tailscale[0-9]*`).

## Usage

Import `default.nix` and declare routes:

```nix
{
  imports = [ ./tailscale-exit-bypass ];

  services.tailscaleExitBypass = {
    enable = true;

    routes.vpn-outer = {
      # Static destinations to send straight out the WAN.
      cidrs = [ "203.0.113.10" "198.51.100.0/24" ];

      # Optional: only match a specific transport/port. Narrow the bypass
      # to just the outer tunnel's UDP port, for example.
      udpDport = 51820;

      # Mark + rule priority. Keep the mark clear of tailscale's
      # 0x80000/0xff0000 mask; keep the priority below ~5210.
      fwmark = "0x42";
      rulePriority = 4500;
    };
  };
}
```

For destinations that rotate, use `cidrSourceCommand` instead of (or alongside)
`cidrs` — any command/script/derivation that prints one IPv4 or CIDR per line.
It runs at apply-time and on every reassert; its output is unioned with `cidrs`,
deduped, and re-validated against a strict IPv4 regex before it reaches nft:

```nix
services.tailscaleExitBypass.routes.dynamic = {
  cidrSourceCommand = pkgs.writeShellScript "endpoints" ''
    grep -hoE '([0-9]{1,3}\.){3}[0-9]{1,3}' /etc/myapp/peers.conf
  '';
  fwmark = "0x43";
  rulePriority = 4501;
};
```

## Options

| Option | Default | Notes |
| --- | --- | --- |
| `enable` | `false` | Master switch. |
| `reassertSeconds` | `60` | Reassert-timer interval for every route. |
| `routes.<name>.enable` | `true` | Per-route switch. |
| `routes.<name>.cidrs` | `[ ]` | Static IPv4 addresses / CIDRs to bypass. |
| `routes.<name>.cidrSourceCommand` | `null` | Command/path/derivation printing extra CIDRs, re-run each reassert. |
| `routes.<name>.udpDport` | `null` | Restrict match to this UDP destination port. |
| `routes.<name>.tcpDport` | `null` | Restrict match to this TCP destination port. |
| `routes.<name>.fwmark` | *(required)* | Hex mark, e.g. `"0x42"`. Avoid tailscale's `0x80000/0xff0000`. |
| `routes.<name>.rulePriority` | *(required)* | ip rule priority, e.g. `4500`. Must be below ~5210. |
| `routes.<name>.probe.enable` | `true` | Periodic health probe. |
| `routes.<name>.probe.intervalSeconds` | `300` | Probe interval. |
| `routes.<name>.probe.forbiddenDevPattern` | `"tailscale[0-9]*"` | BRE the egress dev must NOT match to be healthy. |

You must set at least one of `cidrs` or `cidrSourceCommand` per route (enforced
by an assertion).

## Caveats

- **Fail-open.** If the rules are absent (never installed, or torn down),
  traffic simply falls back to the host default route — i.e. the exit node.
  There is no IP leak beyond "it used the tailnet path you were trying to
  avoid." If you need fail-*closed*, add your own `REJECT` rule in a parallel
  nft table.
- **IPv4 only.** The ruleset, the rule, and the CIDR validation are v4. Add a
  parallel v6 path if you need it.
- **MTU.** Re-routing off `tailscale0` (~1280) onto WAN (~1500) is usually
  fine; a WireGuard outer socket sets DF and PMTUD applies. If a path
  black-holes, pin the *inner* tunnel's MTU lower at the consumer.
- **fwmark / priority hygiene.** The mark and priority are global routing state.
  Pick values that don't collide with tailscale or with other modules on the
  host.
- **CIDR validation is defense-in-depth.** Everything (static and
  command-sourced) is filtered through a strict IPv4 regex before it reaches
  nft, so a compromised resolver, malformed config, or hostile source line
  can't inject arbitrary nft syntax.
