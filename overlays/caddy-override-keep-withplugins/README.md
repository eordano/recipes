# caddy-override-keep-withplugins

Rebuild Caddy against a different Go toolchain (a newer/pinned release, a patched
compiler, whatever) **without losing `caddy.withPlugins`**.

## The problem

You want Caddy built with a specific Go. The obvious move works:

```nix
prev.caddy.override { buildGoModule = prev.buildGoModule.override { go = myGo; }; }
```

...but the resulting `caddy` no longer has `passthru.withPlugins`. Any
downstream code that does `caddy.withPlugins { plugins = [ ... ]; hash = ...; }`
now fails with `attribute 'withPlugins' missing`.

## Why it happens

`withPlugins` is a helper nixpkgs attaches to Caddy via `passthru`, defined in
`pkgs/by-name/ca/caddy/plugins.nix`. Two things break it:

1. **`overrideAttrs` replaces `passthru`** instead of deep-merging, so if you
   `overrideAttrs` the base package the plugin builder is gone.
2. Even the original `withPlugins` closed over the **original** caddy and Go. If
   you preserved it verbatim, plugin builds would use the wrong toolchain — not
   the one you just overrode to.

So there's no way to "keep" the old `withPlugins`; you have to **re-create** it,
bound to your overridden inputs.

## The fix

`callPackage` nixpkgs' own `plugins.nix`, explicitly passing the overridden
`caddy` and `go`, and merge it back onto `passthru`:

```nix
caddy = caddyBase.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    withPlugins = final.callPackage
      "${prev.path}/pkgs/by-name/ca/caddy/plugins.nix"
      { caddy = final.caddy; go = goToolchain; };
  };
});
```

Key points:

- **`final.callPackage` + `caddy = final.caddy`** — refer to the *final*
  (fully-overlaid) caddy so `withPlugins` builds the same package you're
  exporting, including later overlays.
- **`${prev.path}/pkgs/by-name/...`** — reuse upstream's plugins.nix from the
  nixpkgs source tree (`prev.path`) rather than vendoring a copy that will rot.
- **`(old.passthru or { }) // { ... }`** — merge, don't clobber, so any other
  passthru attributes survive.

## Usage

Add `default.nix` to `nixpkgs.overlays`. Edit the `goToolchain` binding to select
your Go:

- Reuse an existing one: `goToolchain = prev.go_1_23;`
- Pin a specific upstream release: override `version` + `src.hash` as shown in
  `default.nix` (get the hash with `nix-prefetch-url` on the
  `go<version>.src.tar.gz` tarball).

After the overlay, both `pkgs.caddy` and `pkgs.caddy.withPlugins { ... }` build
against your toolchain.

## Caveats

- If the pinned Go version's `plugins.nix` interface changes upstream, this may
  need adjusting — it depends on `plugins.nix` accepting `caddy` and `go`
  arguments (true for current nixpkgs).
- Pinning Go by version+src forces a full toolchain rebuild; expect a long first
  build.
