# firewall-by-country

A NixOS module that geo-filters inbound traffic by the **source IP's country**,
using `ipset` hash tables and `iptables`/`ip6tables` (IPv4 + IPv6). Run it as a
global allowlist/blocklist or per network interface.

## The problem

You want a public host to only accept connections from a handful of countries
(allowlist), or to drop traffic from a few (blocklist). A country is millions of
CIDR ranges, so you load them into kernel `ipset` hash tables and match against
them in a single iptables rule.

## The load-bearing insight (the trap)

Country matching is deceptively easy to get catastrophically wrong. The rule
that makes it safe is the **ordering of RETURN rules before the country
match**:

- Match on **source IP only.** Never filter on destination — return traffic
  and locally-originated flows have foreign destinations.
- **RETURN on `ESTABLISHED,RELATED` first.** Otherwise reply packets of your own
  outbound connections get judged by the country filter and dropped.
- **RETURN on every private / loopback / link-local range** *and* on
  **CGNAT `100.64.0.0/10`** (RFC 6598) before the country DROP. Many mesh/VPN
  overlays (Tailscale, for one) assign addresses inside the CGNAT block, so a
  country allowlist that skips it **silently locks out your own management
  network** — you lose SSH to the box and only notice when it's already
  unreachable. Same idea for IPv6: RETURN on loopback, link-local, and
  unique-local (`fc00::/7`), plus your overlay's ULA prefix if it's outside that.
- **Insert the chain at `INPUT` position 1** so it runs ahead of the rest of
  `networking.firewall`.

The module bakes all of this in. Do not remove any RETURN rule to "tidy up."

## How it works

1. For each configured country it builds two ipsets (`country_<cc>` for v4,
   `country6_<cc>` for v6) from prefix lists shipped by a package you provide.
2. It creates a `COUNTRY_FILTER` chain that RETURNs established/local traffic,
   then ACCEPTs (allowlist) or DROPs (blocklist) on the country ipsets, with a
   default action for everything else.
3. It inserts that chain at `INPUT` position 1, and tears it all down cleanly on
   firewall stop.

## Prefix lists (`geoipPackage`)

There is **no upstream package** — you supply one. Point `geoipPackage` at a
derivation laying out:

```
share/geoip-country-lists/<cc>/ipv4-aggregated.txt
share/geoip-country-lists/<cc>/ipv6-aggregated.txt
```

One CIDR per line; lines starting with `#` are ignored. `<cc>` is the lowercase
ISO 3166-1 alpha-2 code. Build this from a source such as
[ipdeny.com](https://www.ipdeny.com/) aggregated zone files or a MaxMind
GeoLite2 country export. Missing files are skipped gracefully (that country just
gets an empty set).

## Usage

```nix
{
  imports = [ ./firewall-by-country ];

  services.firewallByCountry = {
    enable = true;
    geoipPackage = pkgs.myGeoipCountryLists; # your prefix-list package
    mode = "allowlist";
    countries = [ "US" "DE" "FR" ];

    # If your mesh/VPN uses a v6 ULA prefix outside fc00::/7, list it so you
    # don't lock yourself out (Tailscale's default shown here):
    extraAllowedRangesV6 = [ "fd7a:115c:a1e0::/48" ];
  };
}
```

Per-interface rules, overriding the global mode:

```nix
services.firewallByCountry.interfaces = {
  eth0 = { enable = true; mode = "allowlist"; countries = [ "US" "CA" ]; };
  wg0  = { enable = true; mode = "blocklist"; countries = [ "CN" "RU" ]; };
};
```

## Options

| Option | Default | Description |
| --- | --- | --- |
| `enable` | `false` | Turn on global country filtering. |
| `geoipPackage` | `null` | Package providing the prefix lists (required when enabled). |
| `mode` | `"allowlist"` | `allowlist` (only listed countries) or `blocklist` (all but listed). |
| `countries` | `[]` | ISO 3166-1 alpha-2 codes, case-insensitive. |
| `extraAllowedRangesV4` | `[]` | Extra IPv4 CIDRs that bypass the check (added to the built-in private/CGNAT set). |
| `extraAllowedRangesV6` | `[]` | Extra IPv6 CIDRs that bypass the check (added to loopback/link-local/ULA). |
| `interfaces` | `{}` | Per-interface `{ enable; mode; countries; }` rules. |

## Caveats

- **GeoIP is approximate.** Prefix-to-country mapping drifts, and IPs get
  reassigned. Never make it your only access control for something you can't
  afford to be locked out of — keep an out-of-band path (console, a trusted
  `extraAllowedRanges` network).
- **It filters `INPUT` only** (traffic to this host), not forwarded traffic.
- Large countries mean large ipsets; the module sizes hash tables up to 65536
  elements per set, which covers aggregated national zones comfortably.
- Requires the `ip_set_hash_net` and `xt_set` kernel modules (loaded
  automatically) — iptables backend only; the nftables backend needs neither
  (see below).

## nftables backend

This module works on both `networking.firewall.backend = "iptables"` (the
default, as described above) and `"nftables"`. nixpkgs' nftables firewall
hard-asserts `networking.firewall.extraCommands`/`extraStopCommands == ""`,
so the country ipsets and the `INPUT`-position-1 jump chains can't be driven
through them there. Instead the nftables path builds its **own** nftables
table (family `inet`, name `firewall-by-country`), entirely outside
`networking.nftables.tables` (which would delete-and-recreate it, and
therefore the per-country sets, on every ruleset reload — harmless *here*
since those sets are always fully rebuilt from `geoipPackage` anyway, but
kept consistent with how the other affected recipes in this collection
handle nftables tables that do carry state worth protecting).

The translation preserves the load-bearing trap exactly:

- Each enabled interface gets its own nftables chain, plus one more for the
  global filter if `enable = true`; a dispatcher base chain hooked at
  `filter - 10` (ahead of the normal firewall) `jump`s to the per-interface
  chains first and the global chain last — the same order the iptables path
  ends up in after its repeated `-I INPUT 1` inserts.
- `return` inside a jumped-to chain is nftables' equivalent of iptables'
  "`RETURN` to `INPUT`, fall through to the next `-j`": it resumes the
  dispatcher at the next `jump`, so established/related and bypass-range
  traffic still gets a chance to hit a *later* scope (and, if nothing
  terminates, the normal firewall) instead of being silently swallowed.
- The unconditional default-action rule at the end of each chain is a bare
  `accept`/`drop`, which — like iptables `ACCEPT`/`DROP` — is terminal
  immediately, overriding whatever the normal firewall would otherwise have
  decided for that packet.

A `firewall-by-country-nftables` systemd unit (re)builds the whole table in
one atomic `nft -f` transaction on every start, after first deleting it if
present — safe because, again, there's no accumulated state to lose, just
per-country prefix lists derived fresh from `geoipPackage` every time. Prefix
lists are still read from `geoipPackage` at **runtime**, not Nix eval time,
exactly like the iptables path — referencing them in the generated shell
script never forces an import-from-derivation build during evaluation.
