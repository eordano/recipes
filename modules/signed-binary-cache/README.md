# signed-binary-cache

Expose a NixOS store as a **signed** binary cache over HTTPS, so other
machines can pull pre-built derivations from it instead of recompiling.

It is a thin wrapper over `services.nix-serve` (pointed at `nix-serve-ng`, the
Haskell drop-in rewrite, since the nixpkgs default is still the original Perl
`nix-serve`) with nginx terminating TLS in front — plus one deliberate caching
policy that most setups get wrong.

## The problem it solves

You built something expensive on host A. Host B, C, and CI should not rebuild
it from source. The standard answer is a binary cache: A serves its store
paths, and B/C/CI add A to their `substituters`.

Two things make that safe and fast, and this module bakes in both.

## Key insight 1 — sign every narinfo, or clients won't trust it

Nix clients run with `require-sigs = true` by default. They will **refuse** a
substituter unless each narinfo carries a signature made by a key listed in
their `trusted-public-keys`. If you skip signing, you either get nothing from
the cache or have to disable signature checking fleet-wide (don't).

So the cache needs a keypair. Generate it once:

```sh
nix-store --generate-binary-cache-key cache.example.com-1 \
  cache-priv-key.pem cache-pub-key.pem
```

Keep `cache-priv-key.pem` secret and hand it to the module via
`secretKeyFile` (through agenix / sops-nix / a systemd credential — **not** a
path inside the world-readable Nix store). Publish the one-line
`cache-pub-key.pem` so clients can trust the cache.

`secretKeyFile = null` disables signing; only do that for a cache clients
trust by some other means (e.g. it is never exposed publicly).

## Key insight 2 — store paths are immutable, so cache forever

A Nix store path is a content hash: `/nix/store/<hash>-name`. A path that
exists **never changes** — a new build with different contents gets a
different hash and therefore a different path. There is no such thing as a
stale narinfo or NAR for a path that already exists.

That is what licenses the aggressive headers this module sets on every 200:

```nginx
proxy_cache_valid 200 365d;
expires max;
add_header Cache-Control "public, immutable";
```

Any downstream proxy, CDN, or client HTTP cache may hold the response
indefinitely with zero staleness risk. This is the whole reason a binary
cache can sit behind a CDN and serve almost everything from the edge.

## Usage

```nix
{
  imports = [ ./signed-binary-cache ];

  services.signedBinaryCache = {
    enable        = true;
    domain        = "cache.example.com";
    secretKeyFile = "/run/secrets/cache-priv-key.pem";
  };
}
```

Then on every client that should use it:

```nix
{
  nix.settings.substituters        = [ "https://cache.example.com" ];
  nix.settings.trusted-public-keys = [ "cache.example.com-1:<contents of cache-pub-key.pem>" ];
}
```

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Turn the cache on. |
| `domain` | — (required) | Public domain the cache is served on. |
| `port` | `5000` | Port nix-serve listens on; nginx proxies to `<bindAddress>:<port>`. |
| `bindAddress` | `"127.0.0.1"` | Address the plaintext nix-serve backend binds to. Loopback by default (upstream's own default is `0.0.0.0`). |
| `secretKeyFile` | `null` | Path to the private signing key. `null` = unsigned (see insight 1). |
| `enableACME` | `true` | Request a dedicated Let's Encrypt cert for `domain`. |
| `useACMEHost` | `null` | Reuse an existing cert (e.g. a wildcard) instead; mutually exclusive with `enableACME`. |

## Caveats

- **Producer, not proxy.** This module *serves* the local store. Caching an
  upstream like `cache.nixos.org` to save WAN bandwidth is a different job (a
  plain nginx `proxy_cache_path` in front of the upstream) — don't conflate
  the two. A common layout is: this module on build hosts, an upstream-proxy
  cache on a central aggregating node.
- **Signing key handling.** Anyone who can read the private key can forge
  trusted narinfos for your fleet. Treat it as a real secret.
- **You're publishing your store.** nix-serve exposes every path in the local
  store to anyone who can reach the domain. Put it behind auth / a private
  network if the store contains anything you don't want public. The signature
  proves authenticity, not confidentiality.
- **ACME reachability.** With `enableACME = true`, port 80 for `domain` must
  be reachable for the HTTP-01 challenge (or switch to a DNS-01 setup / a
  wildcard via `useACMEHost`).
- **The plaintext backend is bound to loopback, on purpose.** Upstream
  `services.nix-serve.bindAddress` defaults to `0.0.0.0`, which binds the
  unencrypted HTTP socket on every interface; this module overrides that to
  `127.0.0.1` via its own `bindAddress` option. Don't rely on the firewall to
  cover for a wide bind: `networking.firewall.trustedInterfaces` (a VPN
  interface, say) accepts *all* ports on that interface, so a `0.0.0.0` bind is
  reachable there even with `openFirewall = false`. Set `bindAddress` yourself
  only if something other than the local nginx must talk to the backend
  directly — and prefer giving it the TLS vhost instead.
