{
  appName ? "myapp",
}:

final: prev:
let
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

  basePackage =
    prev.${appName} or (final.runCommand appName { } ''
      mkdir -p $out/bin
      cat > $out/bin/${appName} <<'EOF'
      #!${final.runtimeShell}
      export PYTHONPATH='/dummy/site-packages'
      exec ${final.python3}/bin/python -c "import sys" "$@"
      EOF
      chmod +x $out/bin/${appName}
    '');
in
{
  ${appName} = basePackage.overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      substituteInPlace $out/bin/${appName} \
        --replace-fail "export PYTHONPATH='" "export PYTHONPATH='${compatShim}:"
    '';
  });
}
