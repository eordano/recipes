# mlx-lm-python-package

Consume Apple's [`mlx-lm`](https://github.com/ml-explore/mlx-lm) (the MLX
language-model inference library for Apple Silicon) as a Nix-managed Python
package -- from `nixpkgs` by default, and bumped past your channel with an
`overridePythonAttrs` when you need a release it doesn't carry yet.

## The problem

`mlx-lm` gives you efficient local LLM inference on Apple Silicon via the MLX
framework. You want it as a package you can drop into a `python3.withPackages`
interpreter (to `import mlx_lm`, expose the CLI, or run `python -m mlx_lm
server`) -- captured by your system config, not a mutable `pip install` into a
venv that drifts and can't be rolled back.

## The approach

**Use `python3Packages.mlx-lm` -- don't re-package it from PyPI.**

`nixpkgs` ships `mlx-lm`. An earlier version of this recipe built it from the
PyPI sdist with `buildPythonPackage` + `fetchPypi`, a hand-copied `dependencies`
list, and a blanket `doCheck = false`. That was always the expensive option, and
it's the wrong default now:

- `python3Packages.mlx-lm` tracks upstream releases, so a vendored copy is a
  version *behind* the moment you stop babysitting it.
- `buildPythonPackage` does **not** resolve deps from PyPI, so a vendored copy
  means hand-mirroring `pyproject.toml` forever. Miss a new dep and the build
  still succeeds -- the package `ImportError`s at runtime instead.
- Every version bump is a hash bump, done by hand.
- `doCheck = false` throws away the whole test suite. `nixpkgs` instead runs it
  with a precise `disabledTestPaths` list, so the tests that *don't* need a GPU
  or network still gate the build.

So the default is a one-liner: point `callPackage` at `nixpkgs`' package and let
it carry the closure.

```nix
# nixpkgs' mlx-lm:
mlx-lm = pkgs.callPackage ./default.nix { };

# Wrap it into an interpreter, or expose the CLI/server:
python = pkgs.python3.withPackages (_: [ mlx-lm ]);
# then: ${python}/bin/python -m mlx_lm server
```

## Bumping past nixpkgs: override, don't re-vendor

If you need a release newer than your channel (or a fork), override the `nixpkgs`
derivation -- you keep its dependency list, its patches, and its test config, and
change only the source:

```nix
mlx-lm = pkgs.callPackage ./default.nix {
  mlx-lm = pkgs.python3Packages.mlx-lm.overridePythonAttrs (old: rec {
    version = "0.31.4";
    src = old.src.override {
      tag = "v${version}";
      hash = "sha256-...";
    };
  });
};
```

Rebuild; Nix reports the correct `hash` in the failure -- paste it in.

## Traps on the from-PyPI override path

If you ever go the other way and supply your own `fetchPypi` src in an override
(rather than bumping the `tag`/`hash` of the `nixpkgs` src), two small things
make the naive attempt fail in confusing ways:

- **`fetchPypi.pname` needs the underscore name, not the hyphen name.** The
  package is known to humans (and to `pip install`) as `mlx-lm`, but PyPI names
  the *distribution* tarball with an underscore: `mlx_lm-<version>.tar.gz`.
  `fetchPypi` builds the download URL from the `pname` you pass it, so it must be
  the underscore form:

  ```nix
  src = python3Packages.fetchPypi {
    pname = "mlx_lm";   # <-- underscore, or the URL 404s
    inherit version;
    hash = "sha256-...";
  };
  ```

  Pass `mlx-lm` and the fetch fails as a *hash mismatch* -- which sends you
  hunting for the "right hash" when the wrong URL is the real problem. This
  underscore-vs-hyphen split is a general PyPI normalization rule, not specific
  to this package (`mlx_vlm`, etc. behave the same way).

- **`doCheck` must be off for a hand-supplied PyPI src.** The upstream test suite
  expects a GPU (Apple Metal) and downloads real model weights at test time.
  Neither is available in the Nix build sandbox, so the checkPhase can't pass.
  This is exactly the corner `nixpkgs` handles better with `disabledTestPaths`,
  which is why the override-the-`tag` path above is the one to prefer.

## Caveats

- **Apple Silicon only.** MLX is Metal-backed; the `mlx` dependency doesn't exist
  on other platforms, so this only evaluates/builds on a Mac (`aarch64-darwin`).
- To expose the OpenAI-compatible server as a standalone executable rather than a
  bare package, see the sibling `mlx-lm-server` recipe, which wraps
  `python -m mlx_lm server` around this same interpreter.
