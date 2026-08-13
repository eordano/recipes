# nginx-cross-origin-isolated-wasm

A NixOS module that serves a cross-origin-isolated WASM single-page app -- one
that needs `SharedArrayBuffer`, and therefore needs the browser to grant
`crossOriginIsolated` -- from static files behind nginx. It adds one per-vhost
option, `services.nginx.virtualHosts.<name>.crossOriginIsolatedApps.<mount>`,
and generates the location blocks: the COOP/COEP/CORP headers the browser
demands, brotli precompressed sidecars, and a cache policy split between the
stable entrypoint and content-hashed assets. It augments the stock nginx module
in place -- import it and keep configuring `services.nginx` as usual.

## The problem

A WASM app that wants `SharedArrayBuffer` -- multithreaded WebAssembly, a
WebGPU/WebGL2 engine that spawns worker threads, anything that shares memory
across workers -- only gets it in a **cross-origin-isolated** browsing context.
The browser withholds `crossOriginIsolated` (and `SharedArrayBuffer` with it)
until the top-level document arrives with two headers:

- `Cross-Origin-Opener-Policy: same-origin`
- `Cross-Origin-Embedder-Policy: require-corp` (or `credentialless`)

and every subresource the page pulls in -- including the `.wasm` -- is either
same-origin or carries the matching `Cross-Origin-Resource-Policy` / CORS. Miss
one header on one route and the whole app silently loses `SharedArrayBuffer`;
the engine falls back to a single thread, or fails to instantiate at all.

Getting those headers onto the right routes in nginx is where the traps live;
this recipe encodes the ones that cost real debugging time.

## The approach

The module renders, per mount, a small fixed set of locations:

- `= /app` -> a `308` redirect to `/app/`, so the trailing-slash `alias` form is
  the one canonical URL. A root mount (`/`) skips this redirect: it would render
  an empty `location = `, which nginx rejects, and the trailing-slash location
  alone already covers `/`.
- `/app/` -> `alias` onto the built bundle with `brotli_static on`, `try_files`
  falling back to the entrypoint for client-side routing, `Cache-Control:
  no-cache` on the stable-named entrypoint, and the full re-emitted security +
  cross-origin-isolation header block.
- a nested `location ~ ^/app/(?<...>(?:assets|chunks)/.+)$` inside it that
  matches your content-hashed asset directories and flips them to `Cache-Control:
  public, max-age=31536000, immutable` -- re-emitting the COI headers a second
  time, because (see traps) the nested `add_header` drops them again. The mount
  name is sanitised into a bare identifier for that `(?<name>...)` capture group,
  since nginx rejects `-`/`.`/`/` in a capture name -- so a mount like
  `/foo-bar/v2` still produces a valid regex.
- optional `= /app/api` exact-match strip-prefix proxies for the app's
  same-origin API.

It also compiles the brotli module into nginx and turns on
`recommendedBrotliSettings` whenever any mount is configured, because
`brotli_static` needs the module present to serve the `.br` sidecars.

This module pairs with, and deliberately extends,
[`nginx-opinionated-defaults`](../nginx-opinionated-defaults). That module gives
a good server-level security baseline but emits **no**
Cross-Origin-Opener/Embedder/Resource-Policy headers -- and its server-wide
`extraSecurity` COEP is `require-corp`, which breaks any vhost that embeds
cross-origin resources. Cross-origin isolation is a per-route concern, so it
lives here, on the mount that needs it, rather than on the whole server. If you
run both, set `hstsHeader = "$hsts_header"` so the re-emitted HSTS reuses that
module's http-block map.

## Traps

**1. A location-level `add_header` REPLACES the inherited server-level headers.**
This is the load-bearing one. nginx's `add_header` is not additive across
levels: the moment a `location` block contains a single `add_header`, *none* of
the `add_header`s from the enclosing `server` block apply to that location
anymore. So the instant you add COOP/COEP/CORP inside `location /app/`, you have
silently dropped the server block's HSTS (and X-Frame-Options, X-Content-Type-
Options, Referrer-Policy, CSP) on exactly the app's routes. This module's header
block therefore **re-emits HSTS and the rest of the baseline itself**, and does
so again in the nested immutable-assets location, which is a third header scope.
A linter like `gixy` will fail the build on the dropped CSP; the dropped HSTS
just quietly stops protecting your most sensitive routes.

**2. The cache split: no-cache entrypoint vs immutable content-hashed assets.**
The entrypoint (`index.html`, or a stable-named loader) has a name that does not
change between builds, so anything cacheable-by-name pins a returning browser to
a *dead* build after a redeploy: it holds the old `index.html`, which references
asset filenames that no longer exist, and the app 404s itself into a white
screen. So the entrypoint is served `no-cache` (store, but revalidate every
use). Content-hashed assets are the opposite: their filename changes whenever
their bytes change, so they are safe to pin for a year (`immutable`). The nested
regex location is what opts those, and only those, back into far-future caching
-- which is why you must list your hashed-asset directory names in
`immutablePaths`. Leave it empty and everything is served `no-cache`: correct,
but every asset revalidates on every load.

**3. `brotli_static` needs real precompressed sidecars.** The bundle must ship
`foo.js.br` next to `foo.js` (and `engine.wasm.br` next to `engine.wasm`) for
`brotli_static on` to serve the precompressed bytes. If your build doesn't emit
`.br` sidecars, `brotli_static` finds nothing and falls back to the uncompressed
file -- a multi-megabyte `.wasm` shipped raw. `recommendedBrotliSettings`
(enabled here by default) adds on-the-fly brotli as a backstop, but precompressed
sidecars compress harder and cost no request-time CPU.

**4. Exact-match `= /path` strip-prefix `proxy_pass`.** The `apiProxy` entries
render as `location = /app/api { proxy_pass http://upstream/v1; }`. Two details
are load-bearing: the `=` makes the match **exact** (only `/app/api`, nothing
under it), and putting a URI on the `proxy_pass` (`/v1`) makes nginx forward
*exactly that URI* -- the public `/app/api` prefix is stripped, not appended.
Drop the `=` or drop the upstream URI and the public prefix travels upstream, so
the backend sees `/app/api` and every call 404s.

## Usage

```nix
{
  imports = [ ./nginx-cross-origin-isolated-wasm ];

  services.nginx = {
    enable = true;
    virtualHosts."app.example.com" = {
      forceSSL = true;
      enableACME = true;

      crossOriginIsolatedApps."/app" = {
        # Built SPA bundle: index.html at the top, content-hashed assets under
        # assets/ and chunks/, each with a .br sidecar.
        root = pkgs.myWasmApp;

        # Directory names whose files are content-hashed -> immutable caching.
        immutablePaths = [ "assets" "chunks" ];

        # A WASM engine usually needs a wider CSP than the site default.
        contentSecurityPolicy =
          "default-src 'self' https: data: blob:; "
          + "script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; "
          + "worker-src 'self' blob:";

        # require-corp is stricter; credentialless (the default) is more
        # forgiving for an app that fetches from third-party origins.
        embedderPolicy = "credentialless";

        # Same-origin API, prefix-stripped to the backend.
        apiProxy."/app/api" = "http://127.0.0.1:8080/v1";
      };
    };
  };
}
```

Mounting at the site root is the same with `crossOriginIsolatedApps."/"`.

## Options

Per mount (`crossOriginIsolatedApps.<path>.*`):

| Option | Default | Effect |
| --- | --- | --- |
| `root` | (required) | The built SPA bundle directory (store path / derivation), with `.br` sidecars. |
| `index` | `"index.html"` | Entrypoint filename; served no-cache and used as the SPA fallback. |
| `immutablePaths` | `[]` | First-segment names of content-hashed asset dirs -> immutable caching. |
| `embedderPolicy` | `"credentialless"` | COEP value; `require-corp` is stricter. |
| `resourcePolicy` | `"same-origin"` | CORP value -- who may embed this app's own responses. |
| `hstsHeader` | `max-age=63072000; includeSubDomains` | HSTS re-emitted on the app's routes (dropped otherwise). Set to `$hsts_header` to reuse nginx-opinionated-defaults' map. |
| `contentSecurityPolicy` | `null` | Optional (usually widened) CSP for the WASM engine. |
| `extraSecurityHeaders` | `""` | Extra `add_header` lines re-emitted inside every location for the mount. |
| `spaFallback` | `true` | Route unknown paths to the entrypoint for client-side routing. |
| `apiProxy` | `{}` | Exact-match strip-prefix proxies, `<publicPath> -> <upstreamUri>`. |

## Caveats

- `crossOriginIsolatedApps` writes into the vhost's `locations`. If you also
  hand-define `location = /app`, `/app/`, or one of the `apiProxy` paths on the
  same vhost, the two definitions collide in the module merge.
- The `alias` serves from a `/nix/store` path, so `disable_symlinks off` is set
  in the generated blocks; nginx must be allowed to follow the store symlinks.
- Cross-origin isolation is all-or-nothing for the document: any iframe or
  subresource that cannot satisfy COEP will fail to load once the page is
  isolated. `credentialless` softens this for third-party fetches, but embedded
  cross-origin iframes still need their own COEP.
- The default `immutable` lifetime is one year. That is correct only if your
  build truly content-hashes those filenames. A stable-named file placed under
  an `immutablePaths` directory would be pinned to a dead build -- keep hashed
  and stable-named assets in separate directories.
