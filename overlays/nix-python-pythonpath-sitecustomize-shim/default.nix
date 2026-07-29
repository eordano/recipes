# nix-python-pythonpath-sitecustomize-shim
#
# Patch a Nix-built Python application's runtime WITHOUT patching its source,
# by injecting a `sitecustomize.py` onto the wrapper's PYTHONPATH. CPython
# imports `sitecustomize` automatically at interpreter startup (before your app's
# `main`), so any module you drop earliest on PYTHONPATH gets a free "run this
# first" hook. This is the perfect seam for defensive monkeypatches that paper
# over upstream version drift (e.g. a library got bumped in your nixpkgs but the
# app pins an older API shape).
#
# It also shows the sibling trick: overriding a torch-family Python package's
# `src` + `version` in an overlay so it builds against the torch that is actually
# installed in your package set, instead of the stale version the package pins.
#
# This file is a self-contained example overlay. Replace the placeholders marked
# `# EDIT:` with your own package and hashes. Everything else is the reusable
# mechanism.

{
  # The package to patch. Pass your own derivation in; the default is a tiny
  # placeholder so the file evaluates/parses standalone.
  #
  # In real use this is typically a Python app built via buildPythonApplication
  # or a flake's `mkApp`, exposing a `$out/bin/<app>` wrapper script that sets
  #   export PYTHONPATH='...'
  # (the pythonRelaxDeps / makeWrapper style). We rewrite that one line.
  appName ? "myapp",
}:

final: prev:
let
  # -------------------------------------------------------------------------
  # 1. The sitecustomize shim.
  #
  # `writeTextDir "sitecustomize.py" <body>` produces a store path that is a
  # DIRECTORY containing exactly `sitecustomize.py`. Prepending that directory
  # to PYTHONPATH makes CPython auto-import it at startup. Keep every patch in
  # its own bare try/except so a shim failure can NEVER stop the app from
  # booting — a broken monkeypatch that crashes the interpreter is far worse
  # than the bug it was trying to fix.
  #
  # The body below is a generic template. Swap `some_library` /
  # `app.internal.module` / the patched function for whatever your version skew
  # actually requires. The VALUE of this recipe is the injection seam, not this
  # particular patch.
  compatShim = final.writeTextDir "sitecustomize.py" ''
    # Auto-imported by CPython at interpreter startup (it is on PYTHONPATH).
    # Each patch is isolated so a failure can never break application boot.

    # --- Example A: reconcile a changed function signature -------------------
    # An upstream helper changed from "decorator factory" to "bare decorator"
    # (or vice versa) between the version the app pins and the one installed.
    # Wrap it to accept both call conventions.
    try:
        import some_library.util as _util
        _real = _util.some_helper
        def _compat(*args, **kwargs):
            if args and callable(args[0]) and not kwargs:
                return _real(args[0])          # bare-decorator form
            def _decorate(fn):                 # decorator-factory form
                return fn
            return _decorate
        _util.some_helper = _compat
    except Exception:
        pass

    # --- Example B: patch a function inside a module that is not imported yet -
    # The module you need to patch (`app.internal.module`) may only be imported
    # lazily, long after sitecustomize runs. Install an `__import__` wrapper so
    # the patch is (re)attempted every time ANY module is imported, and applies
    # the instant your target module appears in sys.modules. Guard with a flag
    # so it runs once and never recurses.
    try:
        import builtins as _bi, sys as _sys

        _patching = [False]

        def _apply_patch():
            if _patching[0]:
                return
            _m = _sys.modules.get("app.internal.module")
            if _m is None or getattr(_m, "_shim_patched", False):
                return
            if not hasattr(_m, "target_function"):
                return
            _patching[0] = True
            try:
                _orig = _m.target_function

                def _patched(*args, **kwargs):
                    # ... your corrected behavior here; call _orig if useful ...
                    return _orig(*args, **kwargs)

                _m.target_function = _patched
                _m._shim_patched = True
            finally:
                _patching[0] = False

        _real_import = _bi.__import__

        def _wrapped_import(name, globals=None, locals=None, fromlist=(), level=0):
            mod = _real_import(name, globals, locals, fromlist, level)
            _apply_patch()
            return mod

        _bi.__import__ = _wrapped_import
        _apply_patch()  # in case the target is already imported
    except Exception:
        pass
  '';

  # -------------------------------------------------------------------------
  # 2. (Optional) build a torch-family package against the INSTALLED torch.
  #
  # A package like torchaudio pins a specific torch version. If your nixpkgs
  # ships a different torch, building torchaudio's pinned source against the
  # installed torch's buildInputs fails (missing CUDA headers / ABI mismatch,
  # e.g. `cusparse.h` not found). Fix by overriding torchaudio's src+version to
  # MATCH the torch you actually have, while leaving `torch` itself untouched so
  # triton/torch store paths don't fork.
  #
  # This is expressed as an extra Python-package overlay you can feed to a
  # package builder, or apply directly to `pythonPackagesExtensions`.
  torchFamilyVersion = "2.11.0"; # EDIT: match your installed torch version.
  audioPackageOverlay = _: pyPrev: {
    torchaudio = pyPrev.torchaudio.overridePythonAttrs (_: {
      version = torchFamilyVersion;
      src = final.fetchFromGitHub {
        owner = "pytorch";
        repo = "audio";
        tag = "v${torchFamilyVersion}";
        # EDIT: hash for the tag above. Get it with:
        #   nix-prefetch-github pytorch audio --rev v2.11.0
        hash = "sha256-0000000000000000000000000000000000000000000=";
      };
    });
  };

  # Placeholder base package so this overlay parses and evaluates standalone.
  # In real use, REPLACE this with your actual app derivation — e.g. one built
  # from a flake input's builder, passing `audioPackageOverlay` into that
  # builder's Python-package extensions so the torch fix lands in the closure.
  basePackage =
    prev.${appName} or (
      final.runCommand appName { } ''
        mkdir -p $out/bin
        cat > $out/bin/${appName} <<'EOF'
        #!${final.runtimeShell}
        export PYTHONPATH='/dummy/site-packages'
        exec ${final.python3}/bin/python -c "import sys" "$@"
        EOF
        chmod +x $out/bin/${appName}
      ''
    );
in
{
  # -------------------------------------------------------------------------
  # 3. Wire the shim onto the wrapper's PYTHONPATH via postFixup.
  #
  # The app's wrapper script contains a line like:
  #     export PYTHONPATH='/nix/store/...-site-packages:...'
  # We PREPEND the shim directory to it. `--replace-fail` (not `--replace`)
  # is deliberate: if the wrapper's format ever changes and the anchor string
  # is gone, the build FAILS LOUDLY instead of silently shipping without the
  # shim. Adjust the anchor string to match your wrapper's exact quoting.
  #
  # Order matters: the shim dir must come FIRST so `sitecustomize.py` resolves
  # to ours (and so any modules the shim ships shadow the app's).
  ${appName} = basePackage.overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      substituteInPlace $out/bin/${appName} \
        --replace-fail "export PYTHONPATH='" "export PYTHONPATH='${compatShim}:"
    '';
  });
}
