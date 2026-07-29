# mlx-lm-server

Expose Apple's [`mlx-lm`](https://github.com/ml-explore/mlx-lm)
OpenAI-compatible `server` subcommand as a single, pinned Nix executable — so
Apple Silicon LLM inference runs from a reproducible closure instead of a
mutable `pip install` into a venv.

## The problem

`mlx-lm` is the standard way to run LLM inference on Apple Silicon (it's
Metal-backed via Apple's MLX framework). The upstream instructions are
`pip install mlx-lm` and then `mlx_lm.server ...`. That gives you a mutable
venv whose contents drift, aren't captured by your system config, and can't
be rolled back with the rest of the machine.

This recipe wraps the `server` entrypoint as an `mlx-lm-server` bin you can
drop into `environment.systemPackages`, a launchd/systemd `ExecStart`, or a
devshell.

## The key insight

**Don't re-package `mlx-lm` yourself — nixpkgs already does.**

An earlier version of this recipe built the package from the PyPI sdist with
`buildPythonPackage` + `fetchPypi`, a hand-copied `dependencies` list, and a
blanket `doCheck = false`. That is the wrong default now, and it was always the
expensive option:

- `python3Packages.mlx-lm` in nixpkgs tracks upstream releases, so a vendored
  copy is a version *behind* the moment you stop babysitting it.
- `buildPythonPackage` does **not** resolve deps from PyPI, so a vendored copy
  means hand-mirroring `pyproject.toml` forever. Miss a new dep and the build
  still succeeds — the server `ImportError`s at runtime instead.
- Every version bump is a hash bump, done by hand.
- `doCheck = false` throws away the whole test suite. nixpkgs instead runs it
  with a precise `disabledTestPaths` list, so the tests that *don't* need a GPU
  or network still gate the build.

So the recipe is two lines of real content: an interpreter carrying the
package, and a shell wrapper around `python -m mlx_lm server`.

## The remaining traps

- **Call the interpreter, not the console script.** The wrapper runs
  `${python}/bin/python -m mlx_lm server`, where `python` is a
  `python3.withPackages` build. That guarantees the module resolves against
  exactly this closure rather than whatever `mlx_lm` happens to be first on
  `PATH`.

- **`sentencepiece` is missing from the runtime deps.** Upstream declares
  `transformers[sentencepiece]`; nixpkgs carries `sentencepiece` as a
  `nativeCheckInput` only, so it is absent at runtime. Models that ship a
  SentencePiece `tokenizer.model` and no fast `tokenizer.json` then fail to
  load. The recipe adds it back via `extraPythonPackages`; set that to `[ ]` if
  you only serve fast-tokenizer models and want the smaller closure.

- **Override, don't re-vendor.** If you need a release newer than your nixpkgs,
  override the nixpkgs derivation — you keep its dependency list, its patches,
  and its test configuration, and you change only what you meant to change.

## Usage

```nix
# The bin, using nixpkgs' mlx-lm:
pkgs.callPackage ./default.nix { }

# A newer upstream release, without re-vendoring the package:
pkgs.callPackage ./default.nix {
  mlx-lm = pkgs.python3Packages.mlx-lm.overridePythonAttrs (old: rec {
    version = "0.31.4";
    src = old.src.override {
      tag = "v${version}";
      hash = "sha256-...";
    };
  });
}
```

Then run it — all flags pass straight through to `mlx_lm server`:

```sh
mlx-lm-server --model mlx-community/<some-model> --host 127.0.0.1 --port 8080
```

## Caveats

- **Apple Silicon only.** MLX is Metal-backed; the `mlx` dependency only
  evaluates/builds on `aarch64-darwin`. This is not portable to Linux/x86.
- The same wrapping pattern extends to `mlx-vlm` (vision-language models) — see
  the `mlx-vlm-server` recipe, which wraps `python -m mlx_vlm.server` and needs
  build-time source patches on top.
