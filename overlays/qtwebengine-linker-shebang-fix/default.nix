# qtwebengine-linker-shebang-fix
#
# Nixpkgs overlay that fixes a qtwebengine 6.11+ build failure inside the Nix
# sandbox: cmake generates `build/linker_ulimit.sh` with a `#!/bin/bash`
# shebang, but the sandbox has no `/bin/bash`, so the link step dies with
# exit 126 ("bad interpreter").
#
# Why not `patchShebangs`?
#   - The offending script does not exist until *after* cmake configure, so a
#     `patchShebangs` in `patchPhase` runs too early and matches nothing.
#   - `patchShebangs` is a shell function, so it cannot be `find -exec`'d over
#     files discovered later. We use `sed` on the shebang line instead.
#
# The fix rewrites the shebang in BOTH places the file appears:
#   - postPatch: the `linker_ulimit.sh.in` template (before configure).
#   - preBuild:  the generated `linker_ulimit.sh` copy (after configure).
#
# The subtle part — patch BOTH ways qtwebengine is reached:
#   - top-level `qt6.qtwebengine` (e.g. plasma, qutebrowser).
#   - `(qt6.override { ... }).qtwebengine`, which pyside6 / a Python rebind
#     produces. `overrideScope` only reaches the first, so we also wrap
#     `qt6.override` to route the overridden scope through `overrideScope`.
#
# Usage — add to nixpkgs.overlays:
#
#   nixpkgs.overlays = [ (import ./overlays/qtwebengine-linker-shebang-fix) ];
#
# or in a flake:
#
#   pkgs = import nixpkgs {
#     inherit system;
#     overlays = [ (import ./overlays/qtwebengine-linker-shebang-fix) ];
#   };

final: prev:
let
  patchQtwebengine = qfinal: qprev: {
    qtwebengine = qprev.qtwebengine.overrideAttrs (old: {
      # Fix the template before cmake configure copies it.
      postPatch = (old.postPatch or "") + ''
        for f in $(find . -type f \( -name 'linker_ulimit.sh' -o -name 'linker_ulimit.sh.in' \) 2>/dev/null); do
          echo "[qtwebengine-overlay] patching shebang in $f (postPatch)"
          sed -i "1s|^#!.*bash.*|#!$(command -v bash)|" "$f"
        done
      '';
      # Fix the generated copy that only exists after configure.
      preBuild = (old.preBuild or "") + ''
        for f in $(find . -name linker_ulimit.sh -type f 2>/dev/null); do
          echo "[qtwebengine-overlay] patching shebang in $f (preBuild)"
          sed -i "1s|^#!.*bash.*|#!$(command -v bash)|" "$f"
        done
      '';
    });
  };
  applyPatch = q: q.overrideScope patchQtwebengine;
in
{
  qt6 =
    let
      patched = applyPatch prev.qt6;
    in
    patched
    // {
      # Route overridden scopes (e.g. pyside6's `qt6.override { python3 = ...; }`)
      # through the same patch, since `overrideScope` above does not reach them.
      override = args: applyPatch (prev.qt6.override args);
    };
}
