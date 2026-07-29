# geoip-country-lists-package

Package the [ipverse/rir-ip](https://github.com/ipverse/rir-ip) per-country IP
range lists as a **pinned, reproducible Nix derivation**, so firewall /
fail2ban / nginx-geo rules can read country IPv4/IPv6 ranges **from the Nix
store** instead of fetching them live at runtime.

## The problem

You want to allow or block traffic by country at the packet filter (or feed
per-country CIDR sets into fail2ban, nftables `set`s, an nginx `geo` map, etc.).
The RIRs (ARIN, RIPE, APNIC, LACNIC, AFRINIC) publish delegation statistics that
map IP allocations to countries; `ipverse/rir-ip` aggregates those into
per-`ISO-3166` files.

The naive approach is to `curl` those lists at boot or on a timer. That has three
failure modes:

1. **Silent drift.** Your firewall's behaviour changes whenever upstream (or a
   mirror, or a DNS answer) changes. A country's ranges shift and you only find
   out when something is wrongly (un)blocked. Nothing in your config history
   records what the rules *were*.
2. **Boot / network race.** Rules meant to police the network depend on the
   network being up to fetch them. On a cold boot or an offline host the fetch
   fails and you either fail open (no rules) or fail closed (locked out).
3. **Not auditable.** There's no diff to review when the rule set changes.

## The insight

Country IP ranges are **data, and data can be pinned like source.** Wrapping the
list repo in a derivation with `fetchFromGitHub { rev; sha256; }` gives you:

- **Reproducibility** — a rebuild produces byte-identical rules; the ranges only
  change when you deliberately bump `rev`, which is a reviewable diff.
- **Boot-safety** — the store path exists before any interface comes up; no fetch
  races the firewall it configures.
- **Auditability** — updating the range set is a rev+hash change in version
  control, not invisible runtime state.

## Store layout

After building, the derivation exposes the upstream `country/` tree under a
stable prefix:

```
<out>/share/geoip-country-lists/<cc>/ipv4.txt
<out>/share/geoip-country-lists/<cc>/ipv6.txt
<out>/share/geoip-country-lists/<cc>/ipv4-aggregated.txt
<out>/share/geoip-country-lists/<cc>/ipv6-aggregated.txt
```

`<cc>` is the **lowercase** ISO-3166 alpha-2 code (`de`, `us`, `cn`, …). Prefer
the `*-aggregated.txt` files — they merge adjacent CIDRs into the smallest set,
which means fewer rules / smaller nftables sets. Lines beginning with `#` are
comments and must be stripped before feeding the ranges to a rule engine.

## Usage

### As an overlay

```nix
# overlays/geoip-country-lists.nix
final: _: {
  geoip-country-lists = final.callPackage ./geoip-country-lists-package { };
}
```

### Consuming it (example: build an nftables/iptables allow set)

```nix
{ pkgs, lib, ... }:
let
  lists = pkgs.geoip-country-lists;
  countries = [ "de" "us" ];           # lowercase ISO codes
  rangesFor = cc:
    "${lists}/share/geoip-country-lists/${cc}/ipv4-aggregated.txt";
in
{
  # e.g. in a service ExecStart, read + strip comments:
  #   grep -v '^#' ${rangesFor "de"} | while read cidr; do
  #     nft add element inet filter allowed_v4 "{ $cidr }"
  #   done
  environment.etc."geoip/de-v4.txt".source = rangesFor "de";
}
```

The key move in any consumer: **interpolate the store path**, `grep -v '^#'` to
drop comment lines, then load each CIDR into your firewall's set. Because the
path is a store path, the ranges are fixed at build time.

## Updating the pinned data

1. Pick a new commit from `ipverse/rir-ip`.
2. Set `rev` to it and `sha256 = lib.fakeSha256;`.
3. Build once; Nix reports the real hash in the `got:` line — paste it back into
   `sha256`.
4. Nothing else to touch: `version` is `finalAttrs.src.rev`, so it follows the
   pin automatically.
5. Commit. The diff *is* your audit record of what the range set changed to.

## Caveats

- **Coarse geolocation.** This is allocation-level, country-granularity data. It
  is fine for "block/allow an entire country at layer 3". It is **not** city- or
  ASN-level and should not be used for analytics-grade geolocation — use a
  MaxMind GeoLite2 `.mmdb` for that.
- **Country geolocation is inherently imprecise.** VPNs, CDNs, cloud providers,
  and re-allocated blocks mean a per-country filter will have false positives and
  negatives. Treat it as a blunt instrument, not an identity check.
- **You are responsible for freshness.** Pinning is the whole point — it will not
  auto-update. Bump the `rev` on whatever cadence your threat model needs.
- **License.** The upstream repo is MIT-licensed; the underlying RIR delegation
  data has its own terms. Review both before redistributing.

## Files

- `default.nix` — the derivation (call with `callPackage`).
