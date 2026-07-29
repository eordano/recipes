# qtwebengine-linker-shebang-fix

A nixpkgs overlay that fixes a `qtwebengine` 6.11+ build failure inside the Nix
build sandbox.

## The problem

Building `qtwebengine` (directly, or transitively via anything that pulls it in
— Plasma, `qutebrowser`, `pyside6`, …) fails during linking:

```
/build/.../linker_ulimit.sh: /bin/bash: bad interpreter: No such file or directory
... exited with code 126
```

cmake generates `build/linker_ulimit.sh` with a hardcoded `#!/bin/bash`
shebang. The Nix build sandbox has no `/bin/bash`, so the moment the link step
tries to run that script it dies with exit **126** ("bad interpreter").

## Why the obvious fixes don't work

- **`patchShebangs` in `patchPhase` is too early.** `linker_ulimit.sh` does not
  exist yet — cmake only emits it *after* configure runs. A `patchShebangs`
  call in `patchPhase`/`postPatch` matches the `.sh.in` template at best, and
  nothing at worst.
- **`patchShebangs` can't be `find -exec`'d.** It's a shell function, not a
  binary, so you can't discover the generated file later and hand it to
  `patchShebangs` via `find -exec`. You have to rewrite the shebang line
  yourself with `sed`.

So the overlay rewrites the shebang in **two phases**:

| Phase       | Target                         | When it exists            |
|-------------|--------------------------------|---------------------------|
| `postPatch` | `linker_ulimit.sh.in` template | before cmake configure    |
| `preBuild`  | generated `linker_ulimit.sh`   | after cmake configure     |

Each phase does a `sed -i "1s|^#!.*bash.*|#!$(command -v bash)|"` on the first
line only, pointing the shebang at the sandbox's real `bash`.

## The subtle trap: two paths to qtwebengine

`qtwebengine` is reached in more than one way, and a naive `overrideScope`
patch only fixes one of them:

1. **Top-level** `qt6.qtwebengine` — used by Plasma, `qutebrowser`, etc.
   `qt6.overrideScope patchQtwebengine` covers this.
2. **Rebound scope** `(qt6.override { python3 = ...; }).qtwebengine` — `pyside6`
   (and anything that rebinds Qt to a specific Python) calls `qt6.override`,
   which produces a *fresh* package set that your `overrideScope` never touched.

To catch both, the overlay wraps `qt6.override` so every overridden scope is
also run through `overrideScope patchQtwebengine`:

```nix
qt6 = (applyPatch prev.qt6) // {
  override = args: applyPatch (prev.qt6.override args);
};
```

If you only patch the top level, `pyside6` (and friends) will still fail to
build with the same exit-126 error.

## Usage

Add the overlay to your nixpkgs overlay list.

NixOS module:

```nix
{
  nixpkgs.overlays = [ (import ./overlays/qtwebengine-linker-shebang-fix) ];
}
```

Flake / plain `import <nixpkgs>`:

```nix
pkgs = import nixpkgs {
  inherit system;
  overlays = [ (import ./overlays/qtwebengine-linker-shebang-fix) ];
};
```

No options to configure — it's a pure overlay.

## Caveats

- This is a **workaround** for a specific upstream packaging quirk. Once
  nixpkgs (or Qt upstream) makes the generated linker script sandbox-safe, the
  overlay becomes a harmless no-op — the `sed` simply matches nothing. Drop it
  when you confirm `qtwebengine` builds clean without it.
- The shebang match is deliberately loose (`^#!.*bash.*`) so it survives minor
  changes to how cmake writes the line. If a future version renames the script
  or drops the `bash` shebang entirely, revisit the `find -name` patterns.
- Version-observed on `qtwebengine` 6.11.0; the pattern applies to any release
  that emits `linker_ulimit.sh` with an absolute-path bash shebang.
