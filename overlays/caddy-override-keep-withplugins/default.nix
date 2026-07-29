# Overlay: rebuild Caddy against a different Go toolchain WITHOUT losing
# `caddy.withPlugins`.
#
# The trap: `caddy.override { buildGoModule = ...; }` followed by
# `overrideAttrs` gives you a Caddy built with your Go, but it silently
# DROPS `passthru.withPlugins` — the helper nixpkgs exposes to build Caddy
# with extra plugins. `overrideAttrs` replaces `passthru` rather than
# deep-merging the plugin builder back in, and even if you preserve the old
# `passthru`, the stale `withPlugins` still closes over the *original*
# caddy/go, so plugin builds don't pick up your override.
#
# The fix: re-create `withPlugins` by `callPackage`-ing nixpkgs' own
# `pkgs/by-name/ca/caddy/plugins.nix`, explicitly bound to the overridden
# `caddy` and `go`. Then `caddy.withPlugins { plugins = [ ... ]; hash = ...; }`
# builds again, against your toolchain.
#
# Usage: add to `nixpkgs.overlays`. Parameterize the Go package and (optionally)
# a pinned Go version+src via the `let` bindings below.

final: prev:
let
  # --- Pick the Go toolchain Caddy should build against. --------------------
  #
  # Simplest form: just reuse an existing Go from nixpkgs, e.g.
  #     go = prev.go_1_23;
  #
  # This example pins a specific upstream Go release by overriding version+src.
  # Replace version and hash with the release you need (hash is the sha256 of
  # the go<version>.src.tar.gz tarball; get it with `nix-prefetch-url`).
  goToolchain = prev.go.overrideAttrs (_: rec {
    version = "1.26.2";
    src = prev.fetchurl {
      url = "https://go.dev/dl/go${version}.src.tar.gz";
      hash = "sha256-LpHrtpR6lulDb7KzkmqIAu/mOm03Xf/sT4Kqnb1v1Ds=";
    };
  });

  # buildGoModule bound to the chosen toolchain.
  buildGoModule' = prev.buildGoModule.override { go = goToolchain; };

  # Caddy built with the chosen toolchain. `.override` reaches the package's
  # `buildGoModule` argument; this alone still loses `withPlugins`.
  caddyBase = prev.caddy.override { buildGoModule = buildGoModule'; };
in
{
  caddy = caddyBase.overrideAttrs (old: {
    # Merge (don't replace) passthru, then re-bind withPlugins to the
    # overridden caddy + go so plugin builds use the same toolchain.
    passthru = (old.passthru or { }) // {
      # `prev.path` is the path to the nixpkgs source tree, so this reuses
      # upstream's own plugins.nix rather than vendoring a copy.
      withPlugins = final.callPackage
        "${prev.path}/pkgs/by-name/ca/caddy/plugins.nix"
        {
          caddy = final.caddy; # the overridden caddy (this attr)
          go = goToolchain;
        };
    };
  });
}
