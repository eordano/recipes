# pypi-cache-proxy

A local, outage-resilient caching proxy for PyPI. Point a client's index URL
at it to cut WAN traffic and to **keep installing even when PyPI is
unreachable**.

## The problem

A CI fleet or a room full of dev machines re-downloads the same wheels from
PyPI over and over. That wastes bandwidth, and worse: when `pypi.org` has an
outage (or your uplink flaps), every `pip install` fails, even for packages you
already fetched a hundred times.

A single caching layer usually solves the bandwidth problem but *not* the
outage problem — most caches happily return an error or expire an entry the
moment the upstream is down.

## The design: two layers

```
pip → nginx (disk cache, TLS)  →  proxpi (Flask/gunicorn, localhost)  →  PyPI
       └ outage resilience          └ index proxy + its own package cache
```

1. **proxpi** — [EpicWink/proxpi](https://github.com/EpicWink/proxpi), a small
   Flask app run under gunicorn on `127.0.0.1`. It proxies the PyPI index and
   keeps its own package cache.
2. **nginx** — fronts proxpi with a much larger disk-backed `proxy_cache`,
   terminates TLS, and is where the outage resilience actually lives.

Either layer alone is insufficient — the value is in what nginx adds on top.

## The two traps this encodes

Both of these are the reason the module exists; without them a naive proxy
cache does not survive a PyPI outage.

### 1. `proxy_cache_use_stale` — this is the outage resilience

```nginx
proxy_cache_use_stale error timeout http_500 http_502 http_503 http_504 updating;
```

Only nginx runs this. It tells nginx: if the upstream errors, times out, or
returns a 5xx — **serve the stale cached copy anyway**. Combined with
`proxy_cache_background_update on`, clients keep getting previously-seen
packages while a refresh is attempted in the background. This is what turns
"cache" into "keep working when PyPI is down."

### 2. `proxy_ignore_headers Cache-Control` — required, not optional

```nginx
proxy_ignore_headers Cache-Control Expires Set-Cookie;
```

PyPI index pages are served with `Cache-Control: no-cache`. If nginx honors
that header it will refuse to cache the index at all, silently defeating the
whole setup — you'd get bandwidth savings on nothing and zero outage
resilience. Ignoring it lets your own `proxy_cache_valid` rules govern
freshness instead.

## Two other things worth knowing

- **proxpi is built inline.** It is not in nixpkgs, so `default.nix` builds it
  with `buildPythonPackage`. `pythonRelaxDeps = [ "lxml" ]` strips proxpi's
  exact lxml pin so the nixpkgs `lxml` satisfies it without a source rebuild.
- **The proxpi cache is deliberately smaller than the nginx cache** (defaults:
  5 GiB inner, 10 GiB outer). The big, durable, outage-serving cache is the
  nginx one.

## Usage

Import `default.nix` as a NixOS module and enable it:

```nix
{
  imports = [ ./modules/pypi-cache-proxy ];

  modules.services.pypi-cache = {
    enable  = true;
    domain  = "pypi.example.com";  # required
    acmeHost = "example.com";      # optional: reuse an existing ACME cert for TLS
  };
}
```

Then point clients at it:

```ini
# ~/.config/pip/pip.conf  (or a CI env)
[global]
index-url = https://pypi.example.com/index/
```

Check `curl -I` responses for the `X-Cache-Status` header (`HIT` / `MISS` /
`STALE` / `EXPIRED`) to confirm caching is working — `STALE` during a PyPI
outage is the whole point.

### Options

| Option | Default | Purpose |
|---|---|---|
| `enable` | `false` | Turn the service on. |
| `domain` | `null` (**required**) | Virtual host nginx serves the cache on. |
| `acmeHost` | `null` | Existing ACME cert host to reuse for TLS. Null ⇒ no forced SSL (bring your own). |
| `port` | `5000` | Localhost port for the inner proxpi/gunicorn. |
| `user` / `group` | `pypi-cache` | System user/group the proxy runs as. |
| `uid` / `gid` | `null` | Optional fixed ids (null ⇒ auto-allocated). |
| `dataDir` | `/var/lib/pypi-cache` | Inner proxpi package cache directory. |
| `proxpiCacheSize` | `5 GiB` | Inner proxpi cache size, in bytes. |
| `nginxCacheDir` | `/var/cache/nginx/pypi` | Outer nginx disk cache directory. |
| `nginxCacheSize` | `10g` | Max size of the nginx disk cache. |
| `nginxCacheTime` | `30d` | Valid/inactive window for the nginx cache. |

## Caveats

- **nginx is enabled with `mkDefault`.** If you already manage nginx elsewhere,
  the vhost merges in; make sure nothing else claims the same `domain`.
- **`dataDir` should live on persistent storage** with enough room for
  `proxpiCacheSize`. On impermanence-style setups, point it at your persisted
  path.
- The proxpi service is heavily sandboxed (`ProtectSystem = "strict"`,
  empty capability set, syscall filter). It only gets write access to
  `dataDir`; if you relocate the cache, that path is what's whitelisted.
- Pin/refresh the `proxpi` `version` + `sha256` in `default.nix` when you want
  a newer release.
