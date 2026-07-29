# skip-flaky-tests-overlay

A small, reusable nixpkgs overlay toolbox for **surgically disabling package
checks that fail for reasons unrelated to the package being broken** — most
commonly test suites that time out, OOM, or outright crash the CPU emulator
when you build for a foreign architecture under `qemu-user` (binfmt cross
builds), or that flake under a heavily loaded parallel builder.

The value here is not the package list — that is pinned to whatever nixpkgs
revision you happen to be on. The value is **four helper functions and the
ordering/import-check traps they encode**.

## The problem

When you build a package whose upstream binary you can't (or won't) use — a
foreign-arch build running under `qemu-user`, a source build on a busy
builder — the `checkPhase` becomes a liability:

- suites time out because the emulator is 10-50x slower than native,
- pytest gets OOM-killed at high job counts,
- native extension modules trip spurious emulator debug assertions,
- and none of it indicates an actual regression in the package.

You want to drop the *offending check* while keeping the build, and do it with
the smallest possible attribute change (see the caveat about hashes below).

## The helpers

| Helper | What it does | Use when |
| --- | --- | --- |
| `skipChecks pkg` | clears `doCheck` + `doInstallCheck` via `overrideAttrs` | a C / meson / cargo / generic suite is flaky or slow |
| `skipPyChecks pkg` | same, via `overridePythonAttrs` | a Python package's whole pytest run is the problem |
| `skipPyAllChecks pkg` | also clears `pythonImportsCheck` and disables the import hook | **the native module import itself crashes** (see trap) |
| `disablePyTests [names] pkg` | appends to `disabledTests` (pytest `-k` deselection) | only one or two named tests are flaky — keep the rest |

Prefer `disablePyTests` over `skipPyChecks` whenever a single test is the
culprit: you keep coverage for everything else.

## The key trap: `pythonImportsCheck` runs *before* pytest

`buildPythonPackage` has a `pythonImportsCheckHook` that runs during
`installCheck` and **imports every module listed in `pythonImportsCheck`** as a
smoke test. That import happens *before* your test suite runs.

So for a package whose native extension module crashes on import — e.g. a
compiled extension that trips an emulator assertion the moment it's loaded —
setting `doCheck = false` is **not enough**. The crash fires inside the import
hook, not in pytest, and your build still fails. You have to clear the import
list and disable the hook as well. That is exactly what `skipPyAllChecks`
does, and why it exists as a separate helper:

```nix
skipPyAllChecks = pkg:
  pkg.overridePythonAttrs (_: {
    doCheck = false;
    doInstallCheck = false;
    pythonImportsCheck = [ ];        # nothing for the hook to import
    dontUsePythonImportsCheck = true; # and drop the hook itself
  });
```

The canonical example: a plotting extension whose native import aborts the
emulator, plus a second package that imports it during *its own* import check —
both need `skipPyAllChecks`, and `skipPyChecks` silently fails to fix either.

## Usage

Import it as a nixpkgs overlay:

```nix
# plain nixpkgs
import <nixpkgs> {
  overlays = [ (import ./skip-flaky-tests-overlay) ];
}
```

```nix
# NixOS module
{ ... }: {
  nixpkgs.overlays = [ (import ./skip-flaky-tests-overlay) ];
}
```

```nix
# flake
pkgs = import nixpkgs {
  inherit system;
  overlays = [ (import ./skip-flaky-tests-overlay) ];
};
```

Then **replace the illustrative entries in `default.nix` with your own**. Each
entry should carry a one-line comment saying *why* it needs the skip — a skip
without a reason is impossible to retire later.

Notes on the non-Python examples in `default.nix`:

- **meson**: some packages compile their test binaries behind a build flag
  (`-Dtests=true`) independently of `doCheck`. Flip the flag too, or you still
  pay to compile tests you never run.
- **cmake**: you can usually exclude a single failing target
  (`EXCLUDE_TESTS=...`) instead of the whole suite.
- **postPatch rename**: when a package exposes no deselection knob, renaming
  `test_foo` → `no_test_foo` in-source makes the collector skip it.
- **compose**: helpers return a package, so you can chain a further
  `.overridePythonAttrs` to also wire back a missing dependency.

## Caveat: overriding changes the hash

Any `overrideAttrs` / `overridePythonAttrs` changes the derivation's output
hash, so the result **no longer matches the upstream binary cache** and will be
built from source everywhere it's referenced. That is fine — often necessary —
for packages you are already building locally. It is a trap for packages you
were getting from the cache for free: overriding one of those turns a download
into a full (possibly emulated, possibly brutal) source build across your whole
fleet.

Rule of thumb: only reach for these helpers on packages that were going to be
built from source anyway. Leave cache-hitting packages untouched.

## When to retire an entry

These skips are load-bearing but temporary. The *right* fix is usually
upstream (a patched emulator, a fixed test, a nixpkgs bump) — the overlay just
unblocks you meanwhile. Keep the per-entry "why" comments so that when you bump
nixpkgs you can tell which skips are now obsolete and drop them.
