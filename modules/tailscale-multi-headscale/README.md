# tailscale-multi-headscale

Run one **primary** `tailscaled` plus any number of **extra** `tailscaled`
instances — each joined to a *separate* Headscale server — on a single NixOS
host, and survive the two non-obvious traps that setup creates.

Tailscale is built to run one daemon per host. The moment you run a second one
against a different control server, two things break in ways that are painful to
diagnose because every obvious suspect (routes, ACLs, container health, iptables
counters) looks correct. This module encodes the fixes.

## Why you'd want this

- Belong to two independent tailnets at once (e.g. a personal Headscale and a
  work/club one) without one clobbering the other.
- Keep separate identities, ACLs, and exit-node policies per control server.
- Still get a clean per-instance CLI: `tailscale-<name> status` talks to that
  instance's own socket.

Each extra instance gets its own UDP port, TUN interface (`ts-<name>`), state
directory (`/var/lib/tailscale-<name>`), and control socket
(`/run/tailscale-<name>/tailscaled.sock`).

## Trap 1 — the primary daemon's `ts-input` chain silently drops every extra instance's peers

The primary `tailscaled` installs a netfilter chain called `ts-input` that
**drops** inbound CGNAT-range (`100.64.0.0/10`) traffic that doesn't belong to
*it*. Every extra instance's peers live in that same 100.64/10 range, so their
packets arrive on `ts-<name>` and get dropped by the *primary* daemon's rule
before the second daemon ever sees them. Connectivity to the second tailnet
looks half-broken: handshakes start, nothing completes.

**Fix:** insert an early `ACCEPT` for each `ts-<name>` interface *ahead* of the
CGNAT drop, in whichever backend is live. The `tailscale-firewall-fix-<name>`
service:

- probes both the `iptables` and `nftables` `ts-input` chains (NixOS may use
  either),
- waits for the chain to appear (it is created asynchronously after the daemon
  starts),
- inserts the ACCEPT idempotently,
- and no-ops if `ts-input` is absent (which happens when the primary runs
  `--netfilter-mode=off`, in which case there is no drop to work around).

Extra instances themselves run with `--netfilter-mode=off` so they never install
competing netfilter rules — the firewall-fix re-opens the one ACCEPT they need.

## Trap 2 — a Tailscale exit node hijacks your local Docker / libvirt / LAN subnets

Turning on an exit node (`useExitNode`) makes Tailscale install a default route
in **routing table 52** and an **ip-rule at priority 5270** that is consulted
*before* the main table:

```
5270:   from all lookup 52       # default dev tailscale0, plus RFC1918 caught by it
32766:  from all lookup main
```

Table 52's `default dev tailscale0` swallows traffic to local RFC1918 subnets —
Docker bridges (`172.17.0.0/16`, `172.18+.0.0/16`), libvirt networks, and
`192.168.0.0/16` LANs. Symptoms are deceptive: `curl 127.0.0.1:<port>` to a
container connects then hangs, `ping <container-ip>` is 100% loss, nginx returns
502 for Docker-backed services — while container-to-container traffic (same
bridge, pure L2) works fine and every firewall counter reads zero drops.

Diagnostic:

```bash
ip route get 172.18.0.5
#   WRONG:   ... dev tailscale0 table 52 ...
#   CORRECT: ... dev br-xxxxxxxx ...
ip rule list                 # table 52 lookup at 5270, before main
ip route show table 52       # your local subnets pointed at tailscale0
```

**Fix:** pin the RFC1918 ranges back to the `main` table with an ip-rule at
priority **5269** — one slot *ahead* of Tailscale's 5270:

```
ip rule add to 172.16.0.0/12 lookup main priority 5269
ip rule add to 192.168.0.0/16 lookup main priority 5269
```

`172.16.0.0/12` covers the Docker default bridge (`172.17/16`) and all custom
bridges (`172.18+/16`) in one rule. The `local-network-tailscale-routing-fix`
service applies this, gated on `useExitNode != null` **and** Docker or libvirt
being enabled — so plain clients pay nothing.

## Other things the module gets right

- **`anyForwarding` guard** — IP forwarding (`net.ipv4.ip_forward`, etc.) is
  enabled *only* on hosts that actually route (exit node or subnet router), so
  importing the module fleet-wide doesn't quietly turn every laptop into a
  router.
- **`tailscale-exit-node-ensure` timer** — `tailscale up --reset` clears the
  configured exit node, and the init script's re-set loop only retries ~60s
  before giving up *without failing the unit*. A slow boot (wifi not up,
  Headscale unreachable, exit node not yet in the netmap) would otherwise strand
  the host with no exit node. A 2-minute timer re-applies it whenever it's
  found missing.
- **Idempotent, drift-tolerant init** — the init script only forces a re-auth
  when the daemon reports it isn't logged in, so routine activations don't churn
  the session.

## Usage

Import `default.nix` as a NixOS module, then:

```nix
{
  modules.tailscale = {
    enable = true;
    loginServer = "https://headscale.example.com";
    authKeyFile = "/run/secrets/headscale-preauth-key";

    # Optional: use another node as this host's exit node.
    useExitNode = "my-exit-node";

    # A second tailnet on a different Headscale server:
    extraInstances.work = {
      loginServer = "https://headscale.work.example";
      authKeyFile = "/run/secrets/work-headscale-preauth-key";
      port = 41642;                 # must differ from the primary's port
      hostname = "my-laptop-work";  # optional, name in the work tailnet
    };
  };
}
```

Then, on the host:

```bash
tailscale status        # primary tailnet
tailscale-work status   # the "work" instance's own socket
```

### Options

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `enable` | bool | `false` | Enable the primary connection. |
| `authKeyFile` | path (string) | `null` | **Required when enabled.** Runtime path to the preauth key. |
| `loginServer` | string | `https://headscale.example.com` | Primary Headscale URL. |
| `exitNode` | bool | `false` | Advertise this node as an exit node. |
| `useExitNode` | string?| `null` | Route through the named exit node. |
| `acceptRoutes` | bool | `false` | Accept advertised subnet routes. |
| `advertiseRoutes` | list | `[]` | Subnet routes to advertise. |
| `ssh` | bool | `false` | Enable Tailscale SSH (auth by tailnet identity). |
| `derperDomain` | string?| `null` | Co-located DERP relay domain (needs `services.derp-server`). |
| `derperAcmeHost` | string?| `null` | ACME host for the DERP cert (defaults to `derperDomain`). |
| `withoutDerp` | bool | `false` | Run an exit node with no co-located DERP. |
| `logLevel` | enum | `warn` | `verbose`/`debug`/`info`/`warn`/`error`. |
| `extraInstances.<name>` | attrset | `{}` | Per-instance: `loginServer`, `authKeyFile`, `port`, `exitNode`, `useExitNode`, `acceptRoutes`, `hostname`, `logLevel`. |

## Caveats

- **Secret management is out of scope.** Preauth keys are passed as runtime file
  paths (`authKeyFile`). Populate them with agenix, sops-nix, systemd
  credentials, or a plain root-owned file — the module never reads or names your
  secrets.
- **Interface names are capped at 15 chars.** `ts-<name>` must fit the Linux
  interface-name limit; the module asserts this. Keep instance names short.
- **Ports must not collide.** Each extra instance needs a distinct UDP port from
  the primary and from every other instance; the module asserts against the
  primary's port.
- **The DERP relay is optional and external.** `services.derp-server` isn't part
  of nixpkgs — it comes from a separate flake input. This module only emits a
  `services.derp-server` definition when that option is actually declared in your
  configuration (an `optionalAttrs` existence guard), so importing it *without*
  the derp-server module still evaluates cleanly. `mkIf false` alone would not be
  enough: a definition targeting an undeclared option is an eval error regardless
  of its condition. If you run an exit node but have no derp-server module, set
  `withoutDerp = true` to satisfy the exit-node assertion.
- **The routing-fix targets Docker/libvirt RFC1918 ranges.** If you place local
  networks outside `172.16.0.0/12` / `192.168.0.0/16` (e.g. a `10.0.0.0/8` LAN
  you want kept off the exit node), add the matching `ip rule` yourself.
