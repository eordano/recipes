# encrypted-dns-cache

A NixOS module: encrypted DNS (DNSCrypt / DNS-over-HTTPS) fronted by a local
`dnsmasq` cache. Your machine talks to upstream resolvers over an encrypted
channel, while a fast local cache absorbs repeat lookups and survives brief WAN
outages.

## What it solves

Turning on encrypted DNS naively breaks two things that a plain
`/etc/resolv.conf` setup gets for free. This module handles both.

### Trap 1 — `/etc/hosts` overrides survive encrypted upstream

When resolution goes out to an encrypted upstream, it **bypasses your local
`/etc/hosts`**. Any name you pinned in `networking.hosts` (a LAN box, a
split-horizon override, a blackhole entry) silently stops resolving the way you
expect.

The fix: on **every** service start (`preStart`), the module regenerates
`networking.hosts` into a dnscrypt-proxy *cloaking* file and points the resolver
at it. Cloaking rules are applied before the query ever leaves the machine, so
your local overrides keep winning even though the upstream is encrypted. Because
it's regenerated each start, the cloaking file never drifts from your declared
`networking.hosts`.

### Trap 2 — serve stale cache during WAN outages / bufferbloat

When the uplink hiccups (a flaky link, saturation/bufferbloat, a brief ISP
outage), fresh upstream lookups stall or fail and everything that needs DNS
grinds. With `dnsmasq.useStaleCache = true`, dnsmasq's `--use-stale-cache` keeps
answering popular names **instantly from expired cache entries** while it retries
the upstream in the background, instead of returning failure.

## Architecture

```
apps ──> :53 dnsmasq (cache) ──> :10053 dnscrypt-proxy ──> encrypted upstream
                                                             (DNSCrypt / DoH)
```

- `dnsmasq` owns port 53 and is the first cache layer.
- `dnscrypt-proxy` does the actual encrypted resolution on an internal port.
- Optionally `dnscrypt-proxy` runs its own second in-process cache
  (`dnscryptCache`), and/or exposes a local DoH server that you can publish
  through nginx.

## Usage

```nix
{
  imports = [ ./modules/encrypted-dns-cache ];

  modules.dnscrypt-proxy = {
    enable = true;
    dnsmasq.useStaleCache = true;   # keep resolving during WAN blips
  };
}
```

That's the whole minimal setup: `dnsmasq` on :53, encrypted upstream chosen from
your timezone plus Cloudflare/Google as fallbacks, and cloaking rules wired to
`networking.hosts`.

### Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `listenPort` | `53` | Port the resolver serves clients on (localhost). |
| `serverNames` | timezone pick + `cloudflare`, `google` | dnscrypt resolver names to use. |
| `dnsmasq.enable` | `true` | Front dnscrypt-proxy with a dnsmasq cache. |
| `dnsmasq.internalPort` | `10053` | Port dnsmasq forwards to dnscrypt-proxy on. |
| `dnsmasq.useStaleCache` | `false` | Serve expired entries when upstream is unreachable. |
| `dnsmasq.bindInterfaces` | `[]` (all) | Interfaces to bind (e.g. serve a LAN). |
| `dnsmasq.runOutsidePort53` | `false` | Escape hatch to run on a non-53 port. |
| `dnscryptCache` | `false` | dnscrypt-proxy's own in-process cache (second layer). |
| `doh` | `false` | Run a local DNS-over-HTTPS server. |
| `dohPort` | `18053` | Port for the local DoH server. |
| `nginx.enable` + `nginx.domain` | `false` | Reverse-proxy the DoH server behind nginx. |
| `nginx.forceSSL` | `true` | Redirect HTTP→HTTPS on the DoH vhost. |
| `nginx.enableACME` | `true` | Get the vhost cert via `security.acme`. |
| `queryLog.enable` + `queryLog.file` | `false` | Log queries (TSV). |
| `openFirewall` | `false` | Open `listenPort/udp` (only if serving other hosts). |

The default `serverNames` picks a nearby upstream by `config.time.timeZone`
(`America/*`, `Europe/*`, else a global fallback) purely to cut latency, with
Cloudflare and Google as fixed secondaries. Override it to pin your own
resolvers.

## Caveats

- **Port 53 is enforced.** An assertion refuses to let dnsmasq bind a non-53
  port unless you explicitly set `dnsmasq.runOutsidePort53 = true` — clients
  hard-expect DNS on 53.
- The module sets `networking.nameservers = [ "127.0.0.1" ]`,
  `resolvconf.useLocalResolver`, and tells dhcpcd not to touch `resolv.conf`
  (all `mkDefault`, so you can override). Everything on the box resolves through
  the local cache.
- Ordering matters: dnsmasq is ordered `after` dnscrypt-proxy and
  `network-online.target`, and both restart on failure, so the cache never comes
  up pointing at a dead upstream port.
- Only expose the resolver to other machines (`bindInterfaces` + `openFirewall`)
  on a trusted network. `dnscrypt-proxy` itself only ever binds loopback; the
  dnsmasq front-end runs with `bind-dynamic` and, with the default empty
  `bindInterfaces`, has no `interface=` restriction — what keeps it private is
  that `listenPort` stays closed in the firewall until you set
  `openFirewall = true`.

## Security notes

- **The `nginx.enable` DoH proxy enforces TLS by default.** The generated
  virtualHost sets `forceSSL = true` and `enableACME = true`, so enabling it
  requires a working `security.acme` setup (`acceptTerms` + a contact email) —
  the build tells you exactly that if it's missing. If you provision
  certificates another way, set `nginx.enableACME = false` and attach
  `useACMEHost`/`sslCertificate` to the virtualHost yourself. Only set
  `nginx.forceSSL = false` when TLS is terminated in front of nginx: plain-HTTP
  DoH can be read or forged by any on-path observer, defeating the encryption
  the module exists to provide.
