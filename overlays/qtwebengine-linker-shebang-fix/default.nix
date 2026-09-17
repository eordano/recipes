_final: prev:
let
  patchQtwebengine = _qfinal: qprev: {
    qtwebengine = qprev.qtwebengine.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        for f in $(find . -type f \( -name 'linker_ulimit.sh' -o -name 'linker_ulimit.sh.in' \) 2>/dev/null); do
          echo "[qtwebengine-overlay] patching shebang in $f (postPatch)"
          sed -i "1s|^#!.*bash.*|#!$(command -v bash)|" "$f"
        done
      '';
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
      override = args: applyPatch (prev.qt6.override args);
    };
}
