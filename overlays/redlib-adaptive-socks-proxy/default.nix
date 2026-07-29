# Nixpkgs overlay: route redlib's outbound Reddit traffic through a rotating
# pool of SOCKS5 proxies, using a sticky "fastest-first" connector.
#
# See README.md for the full "why". In short: Reddit blocks requests coming
# from datacenter/cloud IP ranges, so a redlib instance hosted anywhere near a
# datacenter gets 403'd. This overlay patches redlib's HTTP client
# (`src/client.rs`) to dial through SOCKS5 proxies taken from the runtime env
# var `ALL_PROXY` (fallback `HTTPS_PROXY`), read as a comma-separated list of
# `socks5://…` URIs. The connector sticks to one backend — reusing a single
# TLS handshake for as many sequential 200-answering requests as possible —
# and only advances to the next proxy when Reddit actually blocks (403 / 5xx).
# You pay the rotation cost when, and only when, you're being blocked.
#
# THE HASH TRAP: the patch adds crate dependencies (hyper-socks2 and its
# transitive deps) to Cargo.toml / Cargo.lock, so the vendored-deps hash
# changes. `fetchCargoVendor` must be re-pinned. The `hash` below WILL NOT
# match your redlib version — set it to `lib.fakeHash`, build once, and copy
# the correct hash from the "got:" line of the mismatch error.
#
# Usage: add to nixpkgs.overlays, e.g.
#   nixpkgs.overlays = [ (import ./overlays/redlib-adaptive-socks-proxy) ];
#
# Then run redlib with the env var pointing at your proxy pool, e.g.
#   ALL_PROXY = "socks5://10.0.0.2:1080,socks5://10.0.0.3:1080";
# (order them fastest-first — the connector honours that order.)

final: prev:
let
  patchedSrc = prev.applyPatches {
    name = "redlib-source-patched";
    src = prev.redlib.src;
    patches = [ ./redlib-socks-connector.patch ];
  };
in
{
  redlib =
    (prev.redlib.overrideAttrs (_old: {
      src = patchedSrc;
    })).overrideAttrs
      (old: {
        # The patch adds crate deps, so the cargo-vendor hash must be
        # recomputed. Set to `prev.lib.fakeHash`, build, and read the correct
        # value from the error. Do NOT reuse a hash from another redlib version.
        cargoDeps = prev.rustPlatform.fetchCargoVendor {
          name = "${old.pname or "redlib"}-${old.version}-vendor";
          src = patchedSrc;
          hash = "sha256-DQ8A5p+e2ZH1W6fjVHGs22we/nCZdhsO60cFMzvUCdM=";
        };
      });
}
