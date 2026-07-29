# egress-filter

Confine a network interface — a VM bridge, a container network — so the guests
behind it can reach **only a named allowlist of domains**, and nothing else on
the internet.

## The problem

You want a domain allowlist: "these VMs may talk to `example.com` and
`cdn.example.org`, period." But a packet filter matches **IP addresses, not
names**, and the IPs behind a name rotate constantly (CDNs, load balancers,
anycast). So a domain allowlist has to be turned into a live IP allowlist, and
that IP set has to stay current or the filter either blocks legitimate traffic
or leaks.

## The approach

A FORWARD chain per interface accepts established/related traffic, allows DNS
(see below), passes through the private/local ranges you list, accepts anything
whose destination is in an **ipset**, and drops the rest. The whole design is
about keeping that ipset correct. Two modes populate it:

### `resolve` mode (simple)

A systemd timer re-resolves every domain (A, AAAA, and one level of CNAME)
through your chosen upstream resolver every `updateInterval` (default 5m) and
rebuilds the ipset.

- **Trap it handles:** the ipset is rebuilt in a **temporary set** and then
  `ipset swap`ped atomically into the name the FORWARD chain matches on. The
  live chain never sees a half-built allowlist — no window where valid
  destinations are briefly missing.
- **Limitation:** it is blind to IP rotations that happen *between* polls. If a
  CDN hands the guest a fresh IP that the box hasn't resolved yet, that
  connection is dropped until the next refresh.

### `dnsmasq` mode (robust)

A per-interface `dnsmasq` becomes the guests' **only** resolver. Its
`ipset=/domain/setname` directive writes each freshly-answered IP into the ipset
**the instant it resolves** — so the guest gets exactly the IP that is now
allowed, with no polling gap.

- **Trap it handles:** a guest could bypass interception by ignoring the offered
  resolver and querying `8.8.8.8` directly. So port 53 (UDP and TCP) from the
  interface is **DNATed to the local dnsmasq**, and IPv6 DNS from the interface
  is dropped outright. The guest cannot resolve names except through the
  interceptor, which means every name it can resolve is a name whose IP just
  entered the allowlist.

Static IP/CIDR overrides and private-network passthrough work in both modes.

## Usage

```nix
{
  imports = [ ./egress-filter ];

  services.egressFilter = {
    enable = true;
    updateInterval = "5m"; # resolve-mode refresh cadence

    interfaces = {
      # Simple: periodic re-resolution.
      virbr0 = {
        enable = true;
        mode = "resolve";
        domains = [ "example.com" "cdn.example.org" ];
        allowedIPs = [ "8.8.8.8" ];
      };

      # Robust: live DNS interception + DNS redirect.
      virbr1 = {
        enable = true;
        mode = "dnsmasq";
        domains = [ "example.com" "cdn.example.org" ];
        allowedIPs = [ "8.8.8.8" "2606:4700:4700::1111" ];
        dnsmasq.listenAddress = "192.168.100.1"; # the bridge's gateway IP
      };
    };
  };
}
```

## Options (per interface)

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Filter this interface. |
| `mode` | `"resolve"` | `"resolve"` (poll) or `"dnsmasq"` (intercept). |
| `domains` | `[]` | Domain names to allow. |
| `allowedIPs` | `[]` | Static IPs/CIDRs (v4 or v6, auto-detected). |
| `allowedIPv4` / `allowedIPv6` | `[]` | Static IPs/CIDRs, explicitly typed. |
| `allowPrivateNetworks` | `true` | Pass through the `privateNetworksV4/V6` ranges. |
| `privateNetworksV4` | loopback + RFC1918 + link-local | Ranges treated as private. |
| `privateNetworksV6` | loopback + link-local + ULA | Ranges treated as private. |
| `allowDNS` | `true` | Allow port 53 to any destination (ignored when `mode = "dnsmasq"` *and* `dnsmasq.redirectDNS` is on — that combination restricts DNS to the local interceptor instead). |
| `dnsServers` | `["1.1.1.1" "8.8.8.8"]` | Upstream resolvers. |
| `dnsmasq.listenAddress` | `""` | Gateway IP dnsmasq binds to (the bridge address). **Required in dnsmasq mode** — an empty value produces a broken config. |
| `dnsmasq.port` | `53` | Interceptor port. |
| `dnsmasq.redirectDNS` | `true` | DNAT the interface's port 53 to the interceptor. |
| `dnsmasq.cacheSize` | `1000` | dnsmasq DNS cache size. |
| `dnsmasq.extraConfig` | `""` | Extra dnsmasq config lines. |

Top-level: `services.egressFilter.enable`, `.updateInterval`, `.interfaces`.

## Caveats

- **Match by destination is coarse.** A shared IP (many domains behind one
  anycast address, or a big cloud front-end) means allowing one domain can
  incidentally allow siblings on the same IP. This is an inherent limit of
  IP-level filtering, not a bug.
- **`resolve` mode has a polling gap.** Prefer `dnsmasq` mode when the allowed
  domains sit behind fast-rotating or huge IP pools.
- **`dnsmasq` mode owns DNS for the interface.** Set `dnsmasq.listenAddress` to
  the interface's gateway IP and make sure guests are handed that resolver.
- **`allowPrivateNetworks` defaults to `true` and bypasses the domain
  allowlist.** Out of the box every guest can reach the *entire* configured
  private range (all of `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`,
  link-local) — i.e. your whole LAN, the host's internal/admin services, the
  router, and other machines — no matter what `domains` says. The filter does
  **not** stop internal lateral movement in this configuration. When confining
  an untrusted guest, set `allowPrivateNetworks = false`, or narrow
  `privateNetworksV4`/`privateNetworksV6` to just the bridge subnet and gateway
  it actually needs.
- **RFC6598 shared address space (the CGNAT range) is *not* in the private
  defaults.** If your guests must reach a CGNAT or overlay-VPN range in that
  block, add it explicitly to `privateNetworksV4`.
- The module forces `networking.firewall.enable = true` and installs its rules
  via `firewall.extraCommands` / `extraStopCommands`, so it coexists with the
  standard NixOS firewall rather than replacing it.

## nftables backend

**Supported**, via a native translation — not the
`networking.firewall.extraCommands`/`extraStopCommands` path the iptables
backend uses (nixpkgs' nftables firewall, `firewall-nftables.nix`, hard-
asserts both of those `== ""`). On `networking.firewall.backend ==
"nftables"` this module instead builds and owns a self-contained nftables
table (family `inet`, name `egress-filter`) through its own systemd unit,
`egress-filter-nftables.service`. Every mode and option this module
supports on iptables — `resolve`, `dnsmasq`, `dnsmasq.redirectDNS`, static
IPs, private-network passthrough, and IPv6 — has a native nftables
equivalent; there is no remaining assertion blocking this backend.

### The two enabling primitives

1. **dnsmasq populates an nftables set directly.** The pinned dnsmasq
   (2.93, built with `HAVE_NFTSET`) accepts
   `--nftset=/<domain>/<sel>#<family>#<table>#<set>`, where `<sel>` is `4`
   or `6` (which record type feeds that spec) and `<family>` is nft's own
   table family (here always `inet`). This was verified against the real
   binary (`dnsmasq --test` accepts the generated directive) and its
   source (`nftset.c`, which — after splitting the spec on `#` — runs
   literally `add element <family> <table> <set> { <ip> }`, i.e. exactly
   the nft command this module's own table expects).
2. **`nft -f <file>` applies as one atomic netlink transaction.** In
   `resolve` mode this replaces `ipset swap`: the timer writes a single
   file containing `flush set ...` followed by every `add element ...`
   for that refresh, and submits it in one `nft -f` call. The live
   enforcement chain never observes a half-rebuilt set — verified by
   applying that exact sequence against a real (network-namespaced)
   nftables/kernel instance, including a simulated redeploy (chain
   teardown + rebuild) between two such rebuilds, confirming the set
   survives untouched.

### Table design: idempotent state, rebuilt enforcement

This module's whole point is dynamic state — the per-interface allow-sets,
populated over time by the `resolve`-mode timer and/or the live `dnsmasq`
interceptor. `networking.nftables.tables` deletes and fully recreates every
table it declares on each `nftables.service` reload (see the
`fail2ban-ipset-geoip-cloudflare` recipe's README for the same finding),
which would wipe that state and reopen the exact polling/interception gap
this module exists to close. So the table is kept **outside**
`networking.nftables.tables`, split into two halves with different update
rules:

- **Table + per-interface sets** (`egress_allow_<iface>` /
  `egress_allow6_<iface>`): created idempotently (`nft add table`/
  `add set`, which — unlike `nft create` — is a no-op if it already
  exists) and **never flushed** by setup or teardown. This is what
  survives a redeploy or a `nftables.service` reload.
- **Enforcement chains** (the per-interface `forward`-hook chain, the
  shared `nat`-hook DNS-redirect chain, and their dispatcher chains): pure
  functions of static config, so they're deleted and rebuilt from scratch
  on every run of `egress-filter-nftables.service` — the dispatcher chains
  are deleted before the chains they jump to, so an unreferenced per-
  interface chain can always be deleted cleanly. This exactly mirrors how
  `fail2ban-ipset-geoip-cloudflare` treats its enforcing "input" chain
  versus its banned-IP set.

Static IPs (`allowedIPv4`/`allowedIPv6`/`allowedIPs`) are seeded into the
same sets via idempotent `add element` (never a flush), so they coexist
safely with whatever the resolve timer or dnsmasq have already added.

### Rule order (load-bearing, identical to the iptables path)

Per enabled interface: `ct state established,related accept` → the DNS
branch (DNAT-and-accept in `dnsmasq`+`redirectDNS` mode, with an explicit
early `drop` of IPv6 DNS traffic before the allow-set is even consulted —
otherwise a guest could resolve names by querying an already-allowed
domain's own IPv6 address on port 53; or a plain accept when `allowDNS`) →
private-network accepts → the allow-set lookup → `drop`. An `inet`-family
table can match `ip`/`ip6` fields side by side in the same chain, so
(unlike the iptables/ip6tables pair) there's one merged chain per
interface instead of two.

### Known residual gaps

- **`networking.nftables.flushRuleset`** (defaulted on for hosts with
  `system.stateVersion` older than 23.11, or explicitly via
  `networking.nftables.ruleset`/`rulesetFile`): every start or reload of
  `nftables.service` — including ones triggered by unrelated firewall
  changes elsewhere on the host — runs `flush ruleset`, wiping this
  module's table (dynamic allow-sets included) until
  `egress-filter-nftables.service` next runs. Affected interfaces are
  unfiltered (fail-open) in that window. This module emits a
  `config.warnings` entry when it detects this combination; consider
  `networking.nftables.flushRuleset = false` if nothing else on the host
  needs it.
- **No table cleanup on full disable.** Disabling `services.egressFilter`
  removes this module's systemd unit from the config entirely, so only
  its *old* `ExecStop` (which deletes just the enforcement chains, by
  design — see above) ever runs. The table and its allow-sets are never
  deleted and linger in the kernel until an operator runs
  `nft delete table inet egress-filter` by hand. This is the same
  tradeoff `fail2ban-ipset-geoip-cloudflare` accepts for its banned-IP set.
- **dnsmasq's live population only ever adds, never removes**, on both
  backends — identical to the pre-existing ipset behavior, not a
  regression from this port.

### Verification performed

- `nix eval`: the iptables-backend resolved config (`extraCommands`,
  `extraStopCommands`, `environment.systemPackages`,
  `networking.firewall.extraPackages`, and every generated systemd unit's
  `ExecStart`/`ExecStartPost`/`preStart`, down to the exact `/nix/store`
  derivation path) is byte-for-byte identical before and after this port.
- Standalone eval with `networking.firewall.backend = "nftables"`
  succeeds with zero failed assertions, for `resolve` mode, `dnsmasq`
  mode, `dnsmasq.redirectDNS`, static IPv4/IPv6, private-network
  passthrough, and IPv6 enabled/disabled.
- Two NixOS VM tests (`egress-filter-nftables-resolve` and
  `egress-filter-nftables-dnsmasq`, siblings of the pre-existing iptables
  `egress-filter-resolve`/`egress-filter-dnsmasq`; they live in the
  configuration this recipe was extracted from and are not shipped
  alongside `default.nix`) boot a hypervisor plus guest VMs on the
  nftables backend and assert a client behind the filtered interface can
  reach an allowed domain and cannot reach a blocked one — including,
  for `dnsmasq` mode, that a guest cannot bypass interception by querying
  an outside resolver directly (the DNAT redirect catches it anyway), and
  for `resolve` mode, that the allow-set survives a simulated redeploy
  (chain teardown + rebuild) with its entries intact. Both passed
  end-to-end against a real kernel.
