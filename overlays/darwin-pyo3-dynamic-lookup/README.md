# darwin-pyo3-dynamic-lookup

A nixpkgs overlay that fixes the macOS-only link failure hit when building a
PyO3 / Rust-based CPython extension module. `pendulum` was the original
motivating example — it no longer needs this (see the correction below) — but
the pattern applies to any not-yet-upstream-patched PyO3 crate.

## The problem

On Darwin the build of a Rust Python extension dies at the link step with a wall
of undefined `_Py*` symbols:

```
Undefined symbols for architecture arm64:
  "_PyExc_ValueError", referenced from: ...
  "_PyModule_Create2", ...
ld: symbol(s) not found for architecture arm64
```

The exact same package builds fine on Linux.

## The insight / trap

A CPython extension module is a shared object that *references* the CPython C API
but is **not** linked against `libpython`. On Linux the dynamic linker resolves
those symbols lazily at load time against the interpreter that imports the
module. macOS's linker (`ld64`) is stricter: by default it insists every symbol
be resolved at **link** time, so the undefined `_Py*` symbols abort the build.

The standard fix is to tell `ld64` those symbols are expected and will be
resolved dynamically at load time:

```
-undefined dynamic_lookup
```

Because the link for a PyO3 crate is driven by `rustc`, the flags are passed
through `RUSTFLAGS` as `-C link-arg=...`:

```
RUSTFLAGS = "-C link-arg=-undefined -C link-arg=dynamic_lookup";
```

Two details that make this a drop-in rather than a one-off:

- **Guard with `stdenv.hostPlatform.isDarwin`.** The flags are only needed on
  macOS. On Linux they are pointless and can mask genuine link errors, so apply
  them only on Darwin.
- **Use `pythonPackagesExtensions`.** This applies the override to *every*
  Python version's package set (`python311Packages`, `python312Packages`, ...),
  so you don't have to figure out which interpreter your app ultimately resolves
  the package through.

Setting `env.RUSTFLAGS` (merged into the derivation's environment) rather than
wrapping the build is the least invasive change and reaches the compiler cleanly.

## Correction (2026-07-28): `pendulum` no longer needs this

This overlay used to ship `pendulum` as its default patched package. That
default is now WRONG and has been removed. In current nixpkgs,
`pkgs/development/python-modules/pendulum/default.nix` carries
`delete-obsolete-cargo-toml.patch` (tracking upstream
python-pendulum/pendulum#979), which deletes an obsolete `rust/.cargo/config.toml`
that had been *suppressing* Maturin's own automatic darwin `dynamic_lookup`
flag injection. With that file gone, Maturin adds the flags itself and the
link succeeds without this overlay. Applying the overlay's `RUSTFLAGS`
override to `pendulum` today buys nothing and, per the cache-hitting caveat
below, forces a pointless from-source rebuild by perturbing the derivation
hash.

The underlying **mechanism stays valid** — it's a real fix for any PyO3
package that hasn't received an equivalent upstream patch — so the overlay
itself is kept, just with no default package baked in. There is no other
generic upstream fix for this class of link error, so recipes/overlays like
this remain the right shape for the next affected package.

## Usage

Importing the file yields an overlay **factory** — call it with an optional
attrset to get the actual overlay. There is **no default package list** (see
the correction above); name the PyO3 package(s) you actually observe the link
error on, as they appear in `pythonXXPackages`:

```nix
nixpkgs.overlays = [
  (import ./darwin-pyo3-dynamic-lookup { packages = [ "orjson" ]; })
];
```

Multiple packages:

```nix
nixpkgs.overlays = [
  (import ./darwin-pyo3-dynamic-lookup { packages = [ "orjson" "some-other-pkg" ]; })
];
```

Only packages that actually exist in the set are touched, so an over-broad list
is harmless on nixpkgs revisions that happen to lack one. Before adding a
package here, check whether its `pkgs/development/python-modules/<name>/default.nix`
already carries an equivalent Darwin patch (like pendulum's) — if it does, this
overlay would only force a needless rebuild.

## Caveat — do not do this to cache-hitting packages

Overriding `RUSTFLAGS` (or `doCheck`, or anything else) perturbs the derivation
hash, so the result no longer matches the upstream binary cache and rebuilds
**from source everywhere**. For a heavy Rust crate — especially under aarch64
emulation — that is a brutal, slow compile you inflict on every machine.

Only add a package here if it is *already* building from source on Darwin (i.e.
one actually hitting the link error). Leave cache-hitting packages untouched.
