# darwin-pyo3-dynamic-lookup
#
# A nixpkgs overlay that fixes the macOS link failure
#
#     Undefined symbols for architecture arm64:
#       "_PyExc_ValueError", referenced from: ...
#       "_PyModule_Create2", ... (and many more _Py* symbols)
#     ld: symbol(s) not found for architecture arm64
#
# seen when building a PyO3 / Rust-based CPython extension module on Darwin.
#
# WHY THIS HAPPENS
#   A CPython extension module is a shared object that references the CPython C
#   API (_PyModule_Create2, _PyExc_ValueError, ...) but does NOT link against
#   libpython. On Linux the dynamic linker resolves those symbols lazily at load
#   time against the already-loaded interpreter. macOS's linker (ld64) is stricter:
#   by default it wants every symbol resolved at LINK time, so the undefined _Py*
#   symbols abort the build. The fix is to tell ld64 that undefined symbols are
#   expected and should be resolved dynamically at load time:
#
#       -undefined dynamic_lookup
#
#   For a Rust/PyO3 crate the link is driven by rustc, so the flags are passed via
#   RUSTFLAGS as -C link-arg=... The extension only needs this on Darwin; on Linux
#   the flags are unnecessary (and can hide real link errors), so guard with
#   stdenv.hostPlatform.isDarwin.
#
# WHY `env` AND `pythonPackagesExtensions`
#   - `pythonPackagesExtensions` applies the override to EVERY Python version's
#     package set (python311Packages, python312Packages, ...) so you don't have to
#     chase which interpreter your app resolves the package through.
#   - Setting `env.RUSTFLAGS` (merged into the derivation environment) rather than
#     wrapping the build reaches the compiler cleanly and is the least invasive
#     change to the upstream derivation.
#
# CAVEAT — do not do this to cache-hitting packages
#   Overriding RUSTFLAGS (or doCheck, etc.) perturbs the derivation hash, so the
#   result no longer matches the binary cache and rebuilds from source everywhere.
#   For a heavy Rust crate under aarch64 emulation that is brutal. Only apply this
#   to packages that are ALREADY building from source on Darwin (i.e. the ones
#   actually hitting the link error) — leave cache-hitting packages untouched.
#
# USAGE
#   Importing this file yields an overlay FACTORY: call it with an (optional)
#   attrset to get the actual `final: prev:` overlay. Add that to
#   `nixpkgs.overlays`:
#
#       nixpkgs.overlays = [
#         (import ./darwin-pyo3-dynamic-lookup { packages = [ "orjson" ]; })
#       ];
#
#   There is no default package list (see the 2026-07-28 correction below) — name
#   the PyO3 packages you actually see the link error on, as found in
#   pythonXXPackages:
#
#       nixpkgs.overlays = [
#         (import ./darwin-pyo3-dynamic-lookup { packages = [ "orjson" "some-other-pkg" ]; })
#       ];
#
#   Only packages that actually exist in the set are touched (see the `? ${name}`
#   guard), so an over-broad list is harmless on nixpkgs revisions that lack one.
#
# CORRECTION (2026-07-28) — `pendulum` was the shipped default; drop it
#   The mechanism above is still valid for any PyO3 package that hasn't been
#   patched upstream. But `pendulum` itself no longer needs it: nixpkgs'
#   `pendulum/default.nix:31-36` now carries `delete-obsolete-cargo-toml.patch`
#   (tracking python-pendulum/pendulum#979), which deletes an obsolete
#   `rust/.cargo/config.toml` that was suppressing Maturin's OWN automatic
#   darwin `dynamic_lookup` flag injection. Maturin adds the flags itself once
#   that stale file is out of the way. Applying this overlay's RUSTFLAGS
#   override to pendulum today does nothing useful and, per the cache-hitting
#   caveat below, forces a pointless from-source rebuild by perturbing the
#   derivation hash. There is accordingly no default package list any more —
#   pass the packages you need explicitly.

{
  # Attribute names of the PyO3 / Rust extension packages to patch, as found in
  # the Python package set (pythonXXPackages.<name>). No default: name the
  # packages you've actually observed the Darwin link failure on (pendulum no
  # longer needs this — see the correction note above).
  packages ? [ ],
}:

final: prev:

let
  inherit (prev) lib;

  # ld64 flags, routed through rustc via -C link-arg. Only meaningful on Darwin.
  darwinRustflags = "-C link-arg=-undefined -C link-arg=dynamic_lookup";

  patchPackage =
    pyFinal: pyPrev: name:
    lib.optionalAttrs (pyPrev ? ${name}) {
      ${name} = pyPrev.${name}.overridePythonAttrs (old: {
        env =
          (old.env or { })
          // lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
            RUSTFLAGS = darwinRustflags;
          };
      });
    };
in
{
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (pyFinal: pyPrev: lib.foldl' (acc: name: acc // patchPackage pyFinal pyPrev name) { } packages)
  ];
}
