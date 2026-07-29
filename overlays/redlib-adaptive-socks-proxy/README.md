# Route Redlib Traffic Through a Rotating SOCKS5 Proxy Pool

A nixpkgs overlay that patches [redlib](https://github.com/redlib-org/redlib)'s
HTTP client to route all Reddit traffic through a **rotating pool of SOCKS5
proxies**, using a *sticky, fastest-first* connector that only rotates when
Reddit actually blocks you.

## The problem

Reddit aggressively blocks requests originating from datacenter / cloud IP
ranges. Host a redlib instance on almost any VPS or colo box and Reddit starts
returning **HTTP 403** (and occasionally 5xx) for its API calls — the frontend
loads but every listing / comment fetch fails. redlib itself dials Reddit
directly over an HTTP/2 rustls client with no proxy support, so there is no
built-in escape hatch.

The usual answer — "just set `HTTP_PROXY`" — doesn't help, because redlib's
`hyper` client is built with a plain `HttpsConnector<HttpConnector>` that
ignores proxy environment variables entirely.

## The approach

Patch `src/client.rs` so the connector is a **pool of SOCKS5 backends** read
from the runtime env var `ALL_PROXY` (fallback `HTTPS_PROXY`), parsed as a
comma-separated list of `socks5://host:port` URIs. The list is treated as
**already ordered fastest-first** (produce that ordering however you like — a
latency-probing sidecar, a static hand-ranked list, etc.).

The connector (`AdaptiveSocks`) is **sticky**: every TCP connect goes through
the *same* backend, identified by a shared atomic index, until something
downstream calls `advance_backend()`. Only a Reddit **403 or 5xx** advances the
index — at which point the next request lands on the next-fastest proxy and
parks there.

The request loop retries up to `MAX_ATTEMPTS` (4) times: on a 403/5xx it calls
`advance_backend()` and retries against the next exit, capped so a fully-blocked
rotation can't loop forever. On a healthy backend the first attempt wins.

## The key insight / trap

**You pay the rotation cost only when you are actually being blocked.** A naive
"pick a random proxy per request" design throws away the TLS session on every
call and multiplies handshake latency across the whole proxy chain. This design
instead:

- Re-enables `hyper`'s connection pool and keeps the connector **stuck** on one
  backend, so a run of successful (200) requests **reuses a single TCP + TLS
  handshake** through one proxy.
- Advances to the next proxy **lazily**, only on a real block signal — so a
  fast, working exit is used until it stops working, not abandoned per-request.

Two non-obvious details baked into the patch:

- **HTTP/1 instead of HTTP/2.** The original client called `.enable_http2()`.
  Tunnelling HTTP/2 through the SOCKS connector is dropped in favour of
  `.enable_http1()` — simpler and reliable through the proxy pool.
- **Pool keys don't include the proxy.** `hyper` keys idle connections by
  `(scheme, host)`, *not* by which SOCKS proxy dialed them. So an
  `advance_backend()` call does **not** eagerly retire pooled connections; the
  new backend is only dialed on the next pool miss, and Reddit sees a fresh TLS
  handshake then. This is fine (and intended) but worth knowing when reasoning
  about *when* a rotation actually takes effect.

- **Request rebuild per attempt.** `hyper::Body` is not `Clone`, so each retry
  reconstructs the `Request` with a fresh empty body and re-applies the (already
  shuffled) header set. The per-iteration cost is trivial next to a Reddit
  round-trip.

## The cargo-vendor hash trap

The patch adds a crate dependency — `hyper-socks2` and its transitive deps
(`async-socks5`, `futures-executor`, `futures-macro`, …) — to `Cargo.toml` and
`Cargo.lock`. That **changes the vendored-dependencies hash**, so
`rustPlatform.fetchCargoVendor`'s `hash` must be recomputed. The hash in
`default.nix` will **not** match your redlib version.

Set it to a fake value and let Nix tell you the right one:

```nix
hash = prev.lib.fakeHash;   # then build; copy the "got:" hash from the error
```

## Usage

Add the overlay to your nixpkgs config:

```nix
{
  nixpkgs.overlays = [
    (import ./overlays/redlib-adaptive-socks-proxy)
  ];
}
```

or when importing nixpkgs directly:

```nix
import nixpkgs {
  inherit system;
  overlays = [ (import ./overlays/redlib-adaptive-socks-proxy) ];
}
```

Then run redlib with the proxy pool in its environment. With the upstream NixOS
module:

```nix
systemd.services.redlib.environment.ALL_PROXY =
  "socks5://10.0.0.2:1080,socks5://10.0.0.3:1080";
```

Order the URIs fastest-first — the connector honours that order and only walks
down the list when Reddit blocks the current exit. redlib will **refuse to
start** (panics in the `LazyLock`) if neither `ALL_PROXY` nor `HTTPS_PROXY` is
set, or if the value parses to zero usable URIs — the proxy pool is mandatory in
this build, by design.

The directory contains:

- `default.nix` — the overlay (`applyPatches` on the source, then re-pins
  `cargoDeps` via `fetchCargoVendor`).
- `redlib-socks-connector.patch` — the source fix to `Cargo.toml`,
  `Cargo.lock`, and `src/client.rs`.

## Caveats

- **Patch line offsets.** The patch targets specific line ranges in
  `src/client.rs`, `Cargo.toml`, and `Cargo.lock`. If your redlib version has
  moved those lines, regenerate the patch against your pinned source. The
  transformation is mechanical: add the `hyper-socks2` dep, add the
  `AdaptiveSocks` connector + `BACKEND_INDEX` + `advance_backend()`, wrap the
  connector, and replace the single-shot `request()` body with the
  retry-on-403/5xx loop.
- **You must supply the proxies.** This overlay does not run or manage any SOCKS
  server or latency prober — it only teaches redlib to *consume* a
  comma-separated `socks5://` list. Point it at whatever pool you operate.
- **No SOCKS auth.** The connector builds each `SocksConnector` with
  `auth: None`. If your proxies need username/password auth, extend the parser
  to carry credentials from the URI into `SocksConnector.auth`.
- **Upstream may add proxy support.** If redlib ships native proxy support,
  prefer it and drop this overlay.
