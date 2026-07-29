# nix-binary-cache-proxy

A pure-nginx caching proxy in front of `cache.nixos.org` (or any Nix binary
cache). No `nix-serve`, no extra daemon — just nginx's own `proxy_cache_path`.

## What it solves

When you have more than one or two machines pulling from the public binary
cache, they all fetch the same NARs over the WAN, over and over. Put this proxy
on one always-on box, point every machine's `substituters` at it, and:

- **Bandwidth**: each derivation crosses the WAN once, then serves from local
  disk at LAN speed.
- **Availability**: when the upstream cache is slow or unreachable, builds keep
  working — cached entries are served stale (`proxy_cache_use_stale updating`)
  instead of failing.

It's a transparent pass-through: NARs are cached and re-served verbatim, so
clients still verify them against the upstream's signing key. This proxy does
**not** re-sign anything.

## Usage

```nix
imports = [ ./nix-binary-cache-proxy ];

modules.services.nix-cache = {
  enable   = true;
  domain   = "cache.example.com";
  acmeHost = "cache.example.com";   # a security.acme cert you configure
  # maxCacheSize = "800g";          # defaults to 50g
};
```

On every client:

```nix
nix.settings.substituters       = [ "https://cache.example.com" ];
nix.settings.trusted-public-keys = [ "cache.nixos.org-1:6NCHdD…" ];
```

Keep the **upstream's** public key — the proxy hands NARs through unchanged.

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `domain` | — | Virtual host the proxy is served under. |
| `acmeHost` | — | `security.acme` cert name for TLS. |
| `upstreamEndpoint` | `cache.nixos.org` | Upstream cache host to proxy. |
| `verifyUpstreamTls` | `true` | Validate the upstream's TLS cert on the WAN fetch. |
| `cacheDir` | `/var/cache/nix-cache-proxy` | On-disk cache location. |
| `maxCacheSize` | `50g` | LRU eviction ceiling for the cache. |
| `cacheLockTimeout` | `60s` | How long a cold-miss herd waits for the request that is filling the entry (see below). |
| `resolver` | `127.0.0.1` | DNS resolver for re-resolving the upstream (see below). |
| `websiteDir` | `null` | Optional static site at `/`; 404s fall through to the proxy. |
| `extraHeaders` | `""` | Extra nginx directives injected into each location. |

## The three non-obvious tricks

### 1. Static-first, proxy-fallback routing — and pinning `/nix-cache-info`

If `websiteDir` is set, `/` serves that directory from disk and only a **404**
falls through (`error_page 404 = @fallback`) to the upstream proxy. But
`/nix-cache-info` is pinned to the proxy in **all** cases (`= /nix-cache-info`),
so Nix clients always get a valid cache-info response even if the static
directory happens to contain a same-named file. Get this wrong and clients
silently treat the store as unusable.

### 2. `directio` + AIO tuning so mirroring doesn't thrash the page cache

Nix NARs are large and a warm cache holds thousands of them. Streaming GBs
through nginx with default settings evicts everything else the kernel had hot.
`directio 8192` makes any response over 8 KiB bypass the page cache on the way
out; `aio on` plus `output_buffers 12 512k` keep those large files streaming
without stalling a worker. The result is that a full mirror pass doesn't
demolish the box's page cache.

### 3. Upstream in an nginx **variable**, not a literal `proxy_pass`

The upstream host lives in `set $upstream_endpoint …` and `proxy_pass` uses the
variable. This forces nginx to re-resolve the host through `resolver` on every
request. If you instead write the hostname literally in `proxy_pass`, nginx
resolves it **once at startup** and freezes that IP until the next config
reload — which breaks the moment a CDN-backed cache like `cache.nixos.org`
rotates addresses. The cost: you **must** provide a working `resolver` (a local
stub resolver, or your LAN DNS). With the variable form and no resolver, nginx
fails the request.

A `proxy_cache_lock` group is also set, and the timeout inside it is the part
that decides whether the lock does anything at all:

- `proxy_cache_lock on` — only one request at a time populates a given cache
  entry.
- `proxy_cache_lock_timeout` (option `cacheLockTimeout`, **default `60s`**) —
  how long the other concurrent requests wait for that one. They are released
  as soon as the entry lands in the cache. **At `0s` they do not wait at all**:
  they are passed straight to the upstream and their responses are *not*
  cached, so on a *cold* miss the lock collapses nothing. `60s` covers a
  typical NAR fill; if the fill is still running when it expires, the waiters
  fall through to the upstream uncached (i.e. `0s` behaviour, delayed). Set
  `cacheLockTimeout = "0s"` if you would rather never wait.
- `proxy_cache_lock_age 300s` — lets a second request take over populating the
  entry if the first is still running after five minutes.
- `proxy_cache_use_stale updating` — serves the old entry to everyone else
  while a refresh is in flight, so a herd asking for an
  already-cached-but-stale NAR collapses into one upstream fetch regardless of
  the lock timeout.

## Caveats

- The `nginx` user needs write access to `cacheDir`; the module adds a tmpfiles
  rule and a `ReadWritePaths` entry for it.
- TLS is required (`forceSSL`). Provision the `acmeHost` certificate separately.
- This caches; it does not sign. Clients trust the upstream key, so the proxy
  can never serve a NAR the upstream wouldn't have.

## Security notes

- **Upstream TLS is verified on the WAN fetch by default**
  (`verifyUpstreamTls = true`): the proxy validates the upstream cache's
  certificate against the system CA bundle
  (`/etc/ssl/certs/ca-certificates.crt`), with SNI and the certificate name
  checked against `upstreamEndpoint`. This is defense-in-depth, not the
  integrity mechanism: end-to-end integrity comes from the Nix client checking
  every narinfo/NAR against the upstream signing key (`trusted-public-keys`),
  so even without it an on-path attacker between the proxy and the CDN could
  only observe which store paths are requested (metadata) or cause denial of
  builds — not inject code clients will accept. Set `verifyUpstreamTls = false`
  only for an upstream whose certificate the system bundle can't validate
  (e.g. a self-signed internal cache), accepting that metadata/DoS exposure.
