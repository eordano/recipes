# harmonia-cache-with-upstream-fallback

Self-host a **signed Nix binary cache** ([harmonia](https://github.com/nix-community/harmonia))
behind nginx so that **one substituter URL transparently covers two things**:

1. this machine's own `/nix/store` (everything it has built), served and
   ed25519-signed by harmonia; and
2. an **on-disk-cached copy of an upstream substituter** (`cache.nixos.org`
   by default), served by an nginx `proxy_cache`.

A request for a path harmonia doesn't have returns `404`; nginx intercepts it
and re-issues against the cached upstream. The **first** peer to pull a path
warms the local disk cache; **every subsequent peer -- and this builder
itself -- then hits local disk instead of the WAN**.

## Why

If you run a build box and a few machines that consume its output, the naive
setup gives everyone two substituters: your box, and `cache.nixos.org`. Every
machine still fetches stdenv/toolchain/etc. from the WAN independently.

Fold both behind a single nginx vhost and the upstream half gets cached to
disk once. Point consumers at just your cache (higher priority than
`cache.nixos.org`) and the LAN warms itself: one WAN fetch per path, ever.

## The traps this module already solves

NAR serving through nginx has a handful of non-obvious footguns; they're all
baked in here:

- **`proxy_buffering off` + `proxy_request_buffering off` + `client_max_body_size 0`.**
  NARs are large and stream-served. Without these, nginx spools whole objects
  to a temp file before forwarding the first byte -- huge latency and disk
  churn.
- **Short 404 TTL (`proxy_cache_valid 404 1m`).** A path genuinely absent
  upstream must not be pinned as "missing" for long, but also must not be
  re-fetched on every retry. One minute is the compromise.
- **DNS re-resolution is opt-in, and needs *both* halves.** A `resolver`
  directive on its own does **not** make nginx re-resolve a proxy target: an
  upstream written literally in `proxy_pass` is resolved once, at config load,
  and pinned until the next reload. Only a `proxy_pass` built from an nginx
  *variable* is resolved per request — and that form in turn *requires* a
  `resolver`. This module therefore emits the two together or neither: set
  `upstreamFallback.resolver` and you get `set $harmonia_upstream …` +
  `proxy_pass https://$harmonia_upstream` + `resolver … valid=30s`; leave it
  `null` (the default) and the endpoint is inlined literally with no resolver
  required. Pick the resolver to match the box — systemd-resolved's stub is
  `127.0.0.53`, a local unbound/dnsmasq is usually `127.0.0.1` — because a
  wrong value fails every fallback request. Left at `null`, the fallback keeps
  working off the address resolved at reload time, which is fine until the
  upstream CDN rotates addresses.
- **`proxy_ssl_server_name on` + `proxy_ssl_name` + `Host` header** set to the
  upstream's own name, so the upstream CDN's TLS/routing is satisfied on the
  re-proxy. The re-proxy also runs `proxy_ssl_verify on` against the system CA
  bundle, since SNI alone does not authenticate the upstream cert.
- **`proxy_cache_lock on`.** Collapses a thundering herd -- when several peers
  ask for the same cold path at once, one fills the cache entry and the rest
  wait on it instead of each opening its own upstream fetch.
- **harmonia binds loopback only; nginx terminates TLS in front of it.** The
  cache is never exposed unencrypted.
- **nginx owns the cache dir.** `proxy_cache_path` lives at `http{}` scope (not
  in the server block), the directory is created via tmpfiles as `nginx:nginx`,
  and it's added to the hardened nginx unit's `ReadWritePaths` -- otherwise the
  unit's sandbox makes it unwritable.

## Usage

Import `default.nix` as a NixOS module, then:

```nix
{
  modules.services.harmonia = {
    enable = true;
    domain = "cache.example.com";
    acmeHost = "cache.example.com";     # cert that fronts the vhost
    signKeyFile = "/run/secrets/cache-priv-key";
    upstreamFallback.enable = true;     # the whole point; optional
  };
}
```

Generate the signing key **once**, off-box:

```sh
nix-store --generate-binary-cache-key cache.example.com-1 \
  cache-priv-key.pem cache-pub-key.pem
```

Deliver the **private** half to `signKeyFile` out of band (agenix, sops-nix, a
systemd credential -- anything that keeps it out of the Nix store) and make it
readable by the `harmonia` service user. Publish the **public** half to every
consumer:

```nix
nix.settings = {
  substituters = [ "https://cache.example.com" ];
  trusted-public-keys = [ "cache.example.com-1:<contents of cache-pub-key.pem>" ];
};
```

Because `priority` defaults to `30` (vs. `cache.nixos.org`'s `40`), consumers
prefer your cache automatically -- you can even drop `cache.nixos.org` from
their substituter list entirely and let the fallback serve it.

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | turn the cache on |
| `domain` | *(required)* | nginx vhost / public cache URL |
| `acmeHost` | *(required)* | ACME cert host fronting the vhost |
| `signKeyFile` | *(required)* | path to the ed25519 secret signing key |
| `port` | `5000` | loopback port harmonia listens on |
| `workers` | `16` | harmonia worker threads |
| `priority` | `30` | advertised substituter priority (lower wins) |
| `upstreamFallback.enable` | `false` | turn on the disk-cached upstream fallback |
| `upstreamFallback.endpoint` | `cache.nixos.org` | upstream substituter to fall back to |
| `upstreamFallback.cacheDir` | `/var/cache/nix-cache` | nginx `proxy_cache` disk store |
| `upstreamFallback.maxCacheSize` | `100g` | eviction ceiling for the disk cache |
| `upstreamFallback.resolver` | `null` | DNS resolver enabling per-request re-resolution of the endpoint (see above) |

## Caveats

- The fallback cache holds **full NARs of everything anyone has ever pulled
  through it**. Size `cacheDir`'s filesystem and `maxCacheSize` accordingly.
- `proxy_intercept_errors` treats `502`/`504` from harmonia as fallback
  triggers too, so a flapping harmonia degrades to serving from upstream
  rather than erroring -- convenient, but it can mask a broken harmonia.
- Requires the `nginx` NixOS module with ACME configured for `acmeHost`.

## Security notes

- **Content trust rests on Nix signatures, not on this transport.** Every NAR
  the fallback caches is signature-verified against each consumer's
  `trusted-public-keys` at install time, so a poisoned cache entry cannot
  install a forged store path. The upstream re-proxy now verifies the upstream
  TLS chain (`proxy_ssl_verify on`), which closes a cache-poisoning / disk-fill
  DoS vector but is not what protects store-path integrity.
- If you point `upstreamFallback.endpoint` at a host that presents a
  **self-signed or private-CA** certificate, `proxy_ssl_verify on` will reject
  it. Add that CA to the system trust store (`security.pki.certificateFiles`)
  or the fallback fetch will fail.
