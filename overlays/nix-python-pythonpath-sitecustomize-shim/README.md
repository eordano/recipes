# nix-python-pythonpath-sitecustomize-shim

Runtime-patch a Nix-built Python application **without patching its source**, by
injecting a `sitecustomize.py` onto the interpreter's `PYTHONPATH`.

## The problem

You build a Python app in Nix (via `buildPythonApplication`, a flake's builder,
etc.). Your nixpkgs bumps a shared library — say `transformers`, `torch`, or any
fast-moving dependency — but the app (or a model package it loads) still targets
the *older* API shape. The app crashes at runtime on a changed signature, a moved
attribute, or a tensor-shape mismatch.

You don't want to fork the app, carry a patch file that rots against every
upstream release, or pin the whole dependency stack backwards. You want a small,
surgical, defensive fix that lives entirely in your overlay.

## The insight

CPython **auto-imports a module named `sitecustomize`** at interpreter startup,
before your app's `main` ever runs — if it can find one on `sys.path`. So if you:

1. write your patch into a `sitecustomize.py`, and
2. put the directory containing it **first** on the app wrapper's `PYTHONPATH`,

then your code runs first, every time, on every invocation of that wrapper — a
free "before-main" hook with zero source changes.

In Nix this is two moves:

- **`writeTextDir "sitecustomize.py" <body>`** — produces a store path that is a
  *directory* containing exactly `sitecustomize.py`.
- **`postFixup` + `substituteInPlace ... --replace-fail`** — rewrite the one line
  in the app's `bin/` wrapper that sets `export PYTHONPATH='...'`, prepending the
  shim directory.

```nix
${appName} = basePackage.overrideAttrs (old: {
  postFixup = (old.postFixup or "") + ''
    substituteInPlace $out/bin/${appName} \
      --replace-fail "export PYTHONPATH='" "export PYTHONPATH='${compatShim}:"
  '';
});
```

## Traps and why the details matter

- **Use `--replace-fail`, not `--replace`.** If a future version of the app
  changes its wrapper format, the anchor string disappears and the build *fails
  loudly* instead of silently shipping a package with no shim — exactly the
  failure mode you want for a patch that is easy to forget about.

- **Order: the shim dir goes FIRST.** `sitecustomize` resolves to the earliest
  match on `sys.path`, and any module the shim ships shadows the app's copy.
  Prepend (`${compatShim}:`), never append.

- **Wrap every patch in a bare `try/except`.** A monkeypatch that throws at
  import time takes the whole interpreter down at startup — strictly worse than
  the bug you were fixing. Each patch must fail closed and let the app boot.

- **Patch lazily-imported modules via an `__import__` wrapper.** If the module
  you need to patch is imported late (after `sitecustomize` runs), you can't
  reach it at startup. Wrap `builtins.__import__` so the patch is re-attempted
  after every import and applies the instant your target lands in
  `sys.modules`. Guard it with a re-entrancy flag and an
  `already-patched` marker so it runs exactly once and never recurses.

## Bonus: build a torch-family package against the *installed* torch

The same file shows a related overlay trick. A package like `torchaudio` pins a
specific `torch` version. If your nixpkgs ships a *different* torch, building
`torchaudio`'s pinned source against the installed torch's build inputs fails
(ABI / missing CUDA headers such as `cusparse.h`).

Fix it by overriding **only** `torchaudio`'s `src` + `version` to match the torch
you actually have, leaving `torch` itself untouched so `triton`/`torch` store
paths don't fork:

```nix
torchaudio = pyPrev.torchaudio.overridePythonAttrs (_: {
  version = "2.11.0";                     # match your installed torch
  src = final.fetchFromGitHub {
    owner = "pytorch"; repo = "audio"; tag = "v2.11.0";
    hash = "sha256-...";                  # nix-prefetch-github pytorch audio --rev v2.11.0
  };
});
```

## How to use

1. Copy `default.nix` into your overlays. It is a *function that returns* an
   overlay: apply it to its `appName` argument first, and the result
   (`final: prev: ...`) is the overlay you register — e.g.
   `nixpkgs.overlays = [ (import ./default.nix { appName = "myapp"; }) ];`.
   `appName` is the name of the package attribute to patch and of its
   `bin/<name>` wrapper.
2. Replace the placeholder `basePackage` with your real app derivation.
3. Rewrite the `sitecustomize.py` body (`compatShim`) with the patches your
   version skew actually needs. The two examples in the file — a
   signature-compat wrapper and a late-import monkeypatch — are templates for the
   two common shapes.
4. If you have a torch/torchaudio mismatch, set `torchFamilyVersion` and the
   `hash`, and feed `audioPackageOverlay` into your app builder's Python-package
   extensions. Otherwise delete that block.
5. Adjust the `--replace-fail` anchor string to match your wrapper's exact
   `export PYTHONPATH='` quoting.

## Caveats

- `sitecustomize` is process-global: it affects **every** interpreter run through
  that wrapper. Scope the shim to the app's wrapper only (via `postFixup` on that
  package), not a shared Python.
- If the app sets `PYTHONNOUSERSITE` or runs with `-S`, `sitecustomize`
  auto-import can be disabled — check the wrapper. The `PYTHONPATH` prepend still
  makes the module *available*, but you may need to `import` it explicitly.
- Monkeypatches against a moving upstream are inherently transient. Keep them
  small, keep the `try/except` guards, and delete them once you upgrade past the
  skew.
