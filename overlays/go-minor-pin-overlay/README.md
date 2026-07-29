# go-minor-pin-overlay

Pin a single Go package back one Go minor when it fails to build on the Go
toolchain your nixpkgs currently ships — without waiting for upstream and
without rolling back the whole nixpkgs pin.

## The problem

nixpkgs bumps its default Go compiler (say 1.25 → 1.26) for the entire tree
at once. Most Go packages follow along fine. A few don't: cgo-heavy code, or
code that leans on unstable/internal Go APIs, often fails to compile on a
fresh minor for weeks until upstream catches up. `gvisor`'s `runsc` is a
recurring example; `caddy` and others show up from time to time too.

Your options look bad: pin the whole nixpkgs back a Go generation (affects
everything), or wait for a fix (blocks your build now).

## The insight

nixpkgs keeps **several Go minors packaged in parallel**, exposed as
`buildGo123Module`, `buildGo124Module`, `buildGo125Module`, … alongside the
default `buildGoModule`. A Go package built with `buildGoModule` takes that
builder as an *overridable argument*. So you can rebuild just the one broken
package against an older, known-good minor and leave the rest of the tree on
the new default.

The entire fix is:

```nix
final: prev: {
  gvisor = prev.gvisor.override { buildGoModule = prev.buildGo125Module; };
}
```

Because it's `.override` (re-invoking the package function with a swapped
argument), not `overrideAttrs` (patching the built derivation), the package
is rebuilt cleanly — `passthru`, tests, and the rest of the derivation stay
intact.

## Usage

1. Edit the two bindings at the top of `default.nix`:
   - `package` — the attribute name of the Go package (e.g. `"gvisor"`).
   - `goMinorBuilder` — the `buildGoNNNModule` to pin to. Choose the last
     minor on which the package built (usually one below the new default).

2. Add the overlay to your config:

   ```nix
   # NixOS
   nixpkgs.overlays = [ (import ./go-minor-pin-overlay) ];
   ```

   ```nix
   # ad-hoc
   import nixpkgs { overlays = [ (import ./go-minor-pin-overlay) ]; };
   ```

3. Rebuild. Remove the overlay once upstream builds on the new default.

To confirm which `buildGoNNNModule` aliases your nixpkgs exposes:

```
nix eval nixpkgs#buildGo125Module --apply builtins.typeOf
```

## Caveats

- **Not every package accepts `buildGoModule` under that name.** If
  `.override { buildGoModule = ...; }` seems to do nothing, inspect
  `prev.<pkg>.override.__functionArgs` to find the real argument name the
  package's `callPackage` signature uses.

- **Minor, not patch.** `buildGoNNNModule` pins a Go *minor*; the patch
  version is whatever nixpkgs currently ships for it. If you need an exact
  Go point release, build a custom module builder and pass that instead:

  ```nix
  let
    goPinned = prev.go_1_26.overrideAttrs (_: rec {
      version = "1.26.2";
      src = prev.fetchurl {
        url  = "https://go.dev/dl/go${version}.src.tar.gz";
        hash = "sha256-...";        # fill in the real hash
      };
    });
    buildGoPinned = prev.buildGoModule.override { go = goPinned; };
  in {
    yourpkg = prev.yourpkg.override { buildGoModule = buildGoPinned; };
  }
  ```

- **This is a stopgap.** An older Go minor may miss security fixes present in
  the new default. Drop the pin as soon as the package builds on the current
  toolchain.
