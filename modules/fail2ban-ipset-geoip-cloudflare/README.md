# fail2ban-ipset-geoip-cloudflare

A NixOS module that backs fail2ban with **kernel ipsets** instead of the stock
one-iptables-rule-per-ban action, seeds a **whitelist** from GeoIP country
ranges and your CDN/reverse-proxy edge ranges, and can optionally **mirror bans
to the Cloudflare edge** via the API.

## The problem

fail2ban's default iptables action inserts one rule per banned IP. Under real
internet scanning traffic that grows to thousands of rules, each traversed
linearly, and — worse — the rules live in a chain that gets torn down and
rebuilt on every firewall reload, so a `nixos-rebuild switch` can silently drop
your active bans.

If you also sit behind a CDN or reverse proxy, two more things bite:

- The connection the firewall sees comes from the **edge**, not the client. Ban
  the source IP naively and you can ban the CDN itself, blackholing *every*
  visitor.
- Legitimate traffic from a trusted region or your own proxy can trip a jail and
  get banned, with no clean override.

## The approach

Two ipsets and exactly one enforcing rule:

- `f2b-banned` — `hash:ip` with a per-entry timeout. Jails add offenders here.
- `f2b-whitelist` — `hash:net`. Trusted networks.

```
iptables -I INPUT 1 -m set --match-set f2b-banned src \
                    -m set ! --match-set f2b-whitelist src -j REJECT
```

Why each piece matters:

- **O(1), unbounded bans.** One rule matches a set membership regardless of how
  many IPs are banned. No rule-per-IP explosion.
- **Bans survive reloads.** The rule is (re)created from
  `networking.firewall.extraCommands`, and the bans themselves live in the
  kernel ipset with timeouts — they outlive firewall restarts, jail reloads, and
  rebuilds. `extraStopCommands` removes only the rule, never the set.
- **Whitelist is an override, not a race.** The single match is "banned **AND
  NOT** whitelisted". A trusted source is dropped from the ban path within the
  same rule evaluation, so there is no window where a ban rule fires before a
  separate allow rule. RFC1918, loopback, GeoIP countries, edge ranges, and your
  own hosts can never be banned even if a jail matches them.
- **CDN-aware.** Whitelist your edge ranges so the edge is never banned. The
  optional Cloudflare action mirrors the ban to the edge firewall, where the
  real client actually connects — that is the only place a masked client IP can
  be blocked.

## The trap (keep it)

ipset stores the entry timeout as a **signed 32-bit int**. The `actionban`
caps `<bantime>` at `2147483` seconds (~24.8 days):

```
TIMEOUT=<bantime>; [ "$TIMEOUT" -gt 2147483 ] && TIMEOUT=2147483
```

A larger bantime overflows and `ipset add` fails — the ban silently doesn't
happen. The cap is load-bearing; don't remove it. (You can still set long jail
`bantime` values for fail2ban's own bookkeeping; the ipset entry is just
re-added as the jail keeps matching.)

## Usage

```nix
{
  imports = [ ./fail2ban-ipset-geoip-cloudflare ];

  services.fail2banIpset = {
    enable = true;

    # Trust whole countries (needs geoipCountrylistPackage below).
    whitelistCountries = [ "de" "at" ];

    # Your own proxy / monitoring / management ranges.
    whitelistIPv4 = [ "198.51.100.10" "203.0.113.0/24" ];
    whitelistIPv6 = [ "2001:db8::1" ];

    # nginx probe/scanner jail (defaults on when services.nginx.enable).
    nginx.enable = true;
    nginx.logPath = "/var/log/nginx/access.log";
  };
}
```

### GeoIP country whitelisting

`whitelistCountries` needs `geoipCountrylistPackage` set to a package that lays
out per-country aggregated prefix lists at:

```
<pkg>/share/geoip-country-lists/<cc>/ipv4-aggregated.txt
<pkg>/share/geoip-country-lists/<cc>/ipv6-aggregated.txt
```

one CIDR per line, `#` comments allowed. There is **no such package in nixpkgs**
— supply your own overlay/derivation built from a public aggregated list such as
[herrbischoff/country-ip-blocks](https://github.com/herrbischoff/country-ip-blocks)
or the ipverse lists. When left `null`, country whitelisting is skipped.

### Edge / CDN ranges

```nix
services.fail2banIpset.edgeRangesFile = "${inputs.cloudflare-ip-ranges}/lists/cloudflare_ips_raw.txt";
```

Any file with one IP/CIDR per line (IPv4 and IPv6 mixed, `#` comments ignored)
works — vendor the Cloudflare list as a flake input, or generate your own. These
ranges go into both the whitelist ipset and fail2ban's `ignoreIP`.

### Mirror bans to Cloudflare (optional)

```nix
services.fail2banIpset.cloudflare = {
  enable = true;
  apiKeyFile = "/run/secrets/cloudflare-fail2ban-token"; # file with a Bearer token
  email = "you@example.com";
};
```

The token needs the *firewall access-rules edit* scope. The action POSTs a
block rule to `user/firewall/access_rules/rules` on ban and deletes it on unban,
treating a `duplicate_of_existing` as success. Provide `apiKeyFile` via your
secret manager (agenix/sops/etc.) — never inline the token.

Note the scope: only the `nginx-protect` jail chains the `cloudflare` action
onto `custom-ipset`. The `kernel-sus-connections` jail bans locally only, which
is what you want — a kernel-level connection refusal is by definition traffic
that reached this host directly, not through the edge.

`apiKeyFile` is typed `str`, not `path`, on purpose: a `path` would let a Nix
path literal (`./cf-token`) copy the live token verbatim into the
world-readable store. Pass a runtime path string.

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `whitelistCountries` | `[]` | Lowercase country codes whose CIDRs join the whitelist set. Requires `geoipCountrylistPackage` (an assertion fires otherwise). |
| `geoipCountrylistPackage` | `null` | Package providing the per-country prefix lists; `null` skips country whitelisting. |
| `whitelistIPv4` | `[]` | Extra IPv4 addresses/CIDRs for the whitelist set *and* fail2ban's `ignoreIP`. |
| `whitelistIPv6` | `[]` | Same for IPv6 (`ignoreIP` entry only when `networking.enableIPv6`). |
| `edgeRangesFile` | `null` | File of CDN/reverse-proxy edge ranges, one IP/CIDR per line. |
| `banTime` | `"96h"` | Default jail bantime. Both bundled jails override it with `168h`; the ipset entry timeout is separately capped at ~24.8 days. |
| `nginx.enable` | `config.services.nginx.enable` | The `nginx-protect` access-log jail. |
| `nginx.logPath` | `/var/log/nginx/access.log` | Access log that jail reads. |
| `kernelJail.enable` | `true` | The `kernel-sus-connections` journal jail. |
| `cloudflare.enable` | `false` | Mirror `nginx-protect` bans to the Cloudflare edge. |
| `cloudflare.apiKeyFile` | *(required when enabled)* | Runtime path **string** to a file holding the Bearer token. |
| `cloudflare.email` | `noreply@example.com` | Exported as `FAIL2BAN_CFUSER`; the token is what actually authenticates. |

## Jails included

- `kernel-sus-connections` — bans hosts the kernel logs as "refused
  connection". Needs firewall connection logging enabled (systemd/journald
  backend). Toggle with `kernelJail.enable`.
- `nginx-protect` — bans obvious probes/scanners from the nginx access log
  (env dotfiles, `cgi-bin`, `boaform`, zgrab/CensysInspect user-agents, PHP/ASP
  scans, …). Edit the `nginxRules` list in `default.nix` to taste.

Both use exponential `bantime-increment` across all jails so repeat offenders
climb quickly.

## Caveats

- IPv6 support keys off `config.networking.enableIPv6`; the module builds a
  parallel `f2b-banned6` / `f2b-whitelist6` and an `ip6tables` rule only then.
- The enforcing rule is inserted at `INPUT` position 1. If you have other
  position-1 insertions, mind ordering — this one wants to be early.
- `127.0.0.0/8` (not `/16`) is whitelisted so all loopback is covered.
- The module owns the `f2b-*` ipset names; don't reuse them elsewhere.

## nftables backend

This module works on both `networking.firewall.backend = "iptables"` (the
default, as described above) and `"nftables"`. nixpkgs' nftables firewall
hard-asserts `networking.firewall.extraCommands`/`extraStopCommands == ""`,
so the nftables path can't use them for the ban/whitelist sets or the
enforcing rule. Instead it keeps its **own** nftables table (family `inet`,
name `fail2ban-ipset`) with equivalent `f2b-banned`/`f2b-whitelist` (and, with
IPv6, `f2b-banned6`/`f2b-whitelist6`) sets and a single early-priority
(`filter - 10`, ahead of the normal firewall) `reject` rule.

That table is deliberately **not** managed through
`networking.nftables.tables`: NixOS deletes and fully recreates every table
declared that way on every `nftables.service` reload — which happens on any
`nixos-rebuild switch` that touches the ruleset — and doing that here would
wipe live bans, defeating the entire point of this module (bans surviving
reloads/switches). A dedicated `fail2ban-ipset-nftables` systemd unit
builds/rebuilds the table with idempotent `nft add table/set` (create-if-
missing, unlike `nft create`) instead, touching only its own enforcing chain
on stop.

The `custom-ipset[6].conf` fail2ban actions switch to
`nft add/delete element inet fail2ban-ipset f2b-banned …` in place of
`ipset add/del`. They keep the same `2147483` second bantime cap: that number
is specifically ipset's signed-32-bit timeout ceiling, and while nftables'
set-element timeout has not been found to share it, that hasn't been verified
against a real kernel either, so the cap is carried over out of caution
rather than assumed safe to widen.
