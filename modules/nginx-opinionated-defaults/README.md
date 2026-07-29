# nginx-opinionated-defaults

A small NixOS module that layers a set of opinionated defaults onto
`services.nginx`, plus a few per-virtual-host knobs. It augments the stock nginx
module in place — import it and keep configuring `services.nginx` as usual.

## The problems it solves

**The stock log format is blind to `Host`.** nginx's built-in `combined` log
format does not record the request `Host` header. On a box serving one vhost
that's fine; on a box serving many, every log line looks identical at the server
level and you cannot tell which site a request hit. That breaks per-vhost
analytics (goaccess), per-vhost intrusion detection (fail2ban filters keyed on
host), and plain `grep`. This module defines a `combined_with_host` format that
appends `"$host"` and points `access_log` at it.

**A note on why the TLS block is hand-rolled — and the cost of that.** An
earlier version of this recipe justified its own TLS block as a way to dodge
OCSP stapling that upstream `recommendedTlsSettings` supposedly forced on. That
premise was simply wrong: `ssl_stapling` appears nowhere in the nixpkgs nginx
module, so there was never anything to dodge. Worse, upstream's block had since
gained a post-quantum hybrid key-exchange group (`ssl_conf_command Groups
"X25519MLKEM768:X25519:P-256:P-384";`) that the hand-rolled one lacked, leaving
this recipe *weaker* than upstream on that axis. The block now carries the same
`Groups` directive, restoring parity.

We still keep our own block (rather than flipping `recommendedTlsSettings` back
on) so the TLS choices are a single explicit source of truth that cannot drift
underneath us — but the flip side is real: **whenever upstream's
`recommendedTlsSettings` changes, re-diff it against
`customRecommendedTlsSettings` here.** Parity is manual now.

**Session/cipher tuning, kept as our own block.** This module supplies its own
TLS session-cache/tickets/cipher-preference settings (`customRecommendedTlsSettings`)
instead of upstream's `recommendedTlsSettings`, purely to keep them declared in
one place we control rather than depending on upstream's block staying
unchanged underneath us.

**HSTS should be set once, everywhere.** Rather than repeat the header per
vhost, the module defines a single `$scheme → $hsts_header` map in the http
block, so every https response carries HSTS.

**Cloudflare hides the real client IP.** When traffic arrives through
Cloudflare, `$remote_addr` is a Cloudflare edge IP. The real client IP is in the
`CF-Connecting-IP` header, but nginx will only trust it from known-Cloudflare
sources. This module reads Cloudflare's *officially published* IP-range list and
emits the `set_real_ip_from` directives for you — so the trust list stays
correct as Cloudflare's ranges change, instead of being hand-copied and going
stale.

## Key trap: `extraSecurity` is off by default on purpose

`extraSecurity` emits a baseline security-header set. One of those headers,
`Cross-Origin-Embedder-Policy: require-corp`, is aggressive: it breaks any page
that loads cross-origin subresources that don't send CORP/CORS headers. Real
apps hit this — Immich is a known example. So the security headers are opt-in
**per vhost**, and you should only enable them for vhosts you know are
self-contained.

A second trap lives in those headers: they reference `$hsts_header`, which is an
nginx *variable*. It must be defined in the http block or nginx refuses to
start. Keep `enableHSTSEverywhere = true` (the default) whenever any vhost uses
`extraSecurity`.

## Usage

Add the module to your host's imports:

```nix
{
  imports = [ ./nginx-opinionated-defaults ];

  services.nginx = {
    enable = true;

    # Global toggles (all shown at their defaults):
    # defaultTweaks = true;                 # gzip/optimisation/proxy on, hardened ciphers
    # enableHSTSEverywhere = true;          # define $hsts_header + HSTS on https
    # customRecommendedTlsSettings = true;  # our own TLS session/cipher/PQ-group block
    # enableCloudflareRealIP = false;       # global real-IP from CF-Connecting-IP
    # extraLogBodies = false;               # load the Lua module for body logging

    virtualHosts."app.example.com" = {
      # ... your usual locations / proxyPass ...

      # Per-vhost knobs added by this module:
      extraSecurity = true;      # baseline security headers (see trap above)
      proxyTimeout = "60s";      # connect/send/read timeout
      clientMaxBodySize = "100m";
      useCloudflareRealIP = true;
    };
  };
}
```

### Wiring the Cloudflare IP-range file

The real-IP features (`enableCloudflareRealIP` globally, `useCloudflareRealIP`
per vhost) need Cloudflare's published range list. Add the upstream repo as a
flake input and point the module at its raw list:

```nix
# flake.nix
inputs.cloudflare-ip-ranges = {
  url = "github:<the-cloudflare-ip-ranges-repo>";
  flake = false;
};
```

```nix
# host config
services.nginx.cloudflareIPRangesFile =
  inputs.cloudflare-ip-ranges + "/lists/cloudflare_ips_raw.txt";
```

The file is any list of CIDRs, one per line (v4 and v6 both accepted); each
becomes a `set_real_ip_from` directive. If you enable a real-IP feature without
setting this path, the module's assertion fails at build time rather than
silently doing nothing.

## Options

Global (`services.nginx.*`):

| Option | Default | Effect |
| --- | --- | --- |
| `defaultTweaks` | `true` | gzip + optimisation + proxy recommended settings on; upstream `recommendedTlsSettings` off; hardened `sslCiphers`. |
| `enableHSTSEverywhere` | `true` | Defines `$hsts_header` and sends HSTS on https. Required by `extraSecurity`. |
| `hstsHeader` | `max-age=31536000; includeSubdomains; preload` | HSTS policy value; override to drop `preload`/`includeSubdomains`. |
| `customRecommendedTlsSettings` | `true` | TLS session cache/tickets/cipher-preference tuning plus the `X25519MLKEM768` PQ key-exchange group, kept at parity with upstream's `recommendedTlsSettings`. |
| `enableCloudflareRealIP` | `false` | Global real-client-IP from `CF-Connecting-IP`. Needs `cloudflareIPRangesFile`. |
| `cloudflareIPRangesFile` | `null` | Path to Cloudflare's CIDR list (one per line). |
| `securityHeaders` | baseline set | The header block `extraSecurity` emits; override to customise. |
| `extraLogBodies` | `false` | Load the Lua module (for body-logging snippets). |

Per virtual host (`services.nginx.virtualHosts.<name>.*`):

| Option | Default | Effect |
| --- | --- | --- |
| `extraSecurity` | `false` | Emit `securityHeaders` (+ safe proxy params). Can break cross-origin apps — see trap. |
| `safeProxyParameters` | `true` | With `extraSecurity`, also emit conservative proxy timeouts / body size. |
| `useCloudflareRealIP` | `false` | Per-vhost real-IP from Cloudflare. Needs `cloudflareIPRangesFile`. |
| `proxyTimeout` | `null` | Override connect/send/read timeout, e.g. `"60s"`. |
| `clientMaxBodySize` | `null` | Override `client_max_body_size`, e.g. `"100m"`. |

## Caveats

- The custom log format writes to `/var/log/nginx/access.log`. If you also
  configure per-vhost `access_log`, be aware the http-level directive here is
  the default sink.
- `enableCloudflareRealIP` only makes sense when traffic really does arrive
  through Cloudflare. Behind a different proxy, trust that proxy's ranges
  instead (this module doesn't do that for you).
- The hardened `sslCiphers` string drops older cipher suites; ancient clients
  may fail to connect. That's intended.

## Security notes

- **The default HSTS header is `max-age=31536000; includeSubdomains; preload`,
  and it is hard to undo.** `includeSubdomains` forces every current and future
  subdomain of the served domain to be HTTPS-only, so a later plain-HTTP
  subdomain (e.g. a legacy internal service) will be refused by any browser that
  saw the header. `preload` asserts the domain may be added to browsers'
  built-in HSTS preload list; getting removed from that list takes months. If
  you are not ready to commit every subdomain to HTTPS forever, set the
  `hstsHeader` option to a weaker policy (e.g. `"max-age=31536000"`), or set
  `enableHSTSEverywhere = false` entirely — before the first request goes out.
