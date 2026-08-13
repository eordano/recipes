# deno-prebuilt-darwin-overlay

A nixpkgs overlay that swaps the source-built `deno` for the **official
prebuilt release binary** -- but only on macOS.

## The problem

On macOS, building `deno` from source through nixpkgs fails: deno bundles
V8 via the `rusty-v8` crate, and that source build reliably breaks on the
darwin toolchain. If anything in your closure pulls in `deno` (directly, or
transitively through tools like jitsi/invidious adapters that shell out to
it), your whole Mac build goes down with it.

## The insight

You don't need to compile deno. The deno project publishes prebuilt
release binaries for every platform on GitHub. The fix is
to override the `deno` attribute on darwin with a trivial derivation that
just downloads the release zip and unpacks the executable -- no compiler, no
V8, no `rusty-v8`.

The override is scoped to darwin only (`lib.optionalAttrs
stdenv.hostPlatform.isDarwin`), so Linux and everything else keep using the
normal nixpkgs source build, which works fine there.

## Usage

Add it to your overlays:

```nix
nixpkgs.overlays = [ (import ./overlays/deno-prebuilt-darwin-overlay) ];
```

or with flakes:

```nix
pkgs = import nixpkgs {
  inherit system;
  overlays = [ (import ./overlays/deno-prebuilt-darwin-overlay) ];
};
```

After that, `pkgs.deno` on a Mac resolves to the prebuilt binary; on Linux
it is untouched.

## Bumping the version

The version and hashes are pinned inside `default.nix` -- this is a
fixed-output derivation, so both go stale on every deno release.

1. Change `version`.
2. Update the matching `hashes` entries. For each arch:

   ```sh
   nix store prefetch-file --json \
     https://github.com/denoland/deno/releases/download/v<VERSION>/deno-<ARCH>.zip
   ```

   where `<ARCH>` is `aarch64-apple-darwin` or `x86_64-apple-darwin`. Or set
   a hash to `lib.fakeHash` and let the failing build print the correct one.

## Caveats

- **Both darwin arches are wired up**, but only the Apple Silicon
  (`aarch64-apple-darwin`) hash is filled in with a real value out of the
  box. The Intel (`x86_64-apple-darwin`) entry ships as `lib.fakeHash` -- fill
  it in (see above) before building on an Intel Mac, otherwise that build
  fails loudly with the correct hash to paste in. Non-darwin systems hit an
  explicit `throw`.
- This bypasses the source build entirely, so you get whatever deno ships in
  its release binary -- including its bundled V8. That's the point, but it
  does mean you trust the upstream release rather than a from-source build.
- Fixed-output hashes rot on every upstream release; keep the version and
  hashes in sync when you bump.
