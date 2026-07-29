# mlx-lm-server — Apple MLX `mlx_lm server` as a standalone Nix bin.
#
# A thin wrapper over nixpkgs' `python3Packages.mlx-lm`: build an interpreter
# that carries the package (and its full dependency closure), then expose the
# OpenAI-compatible `server` subcommand as a single executable. The result is a
# reproducible closure you can drop into `environment.systemPackages`, a
# launchd/systemd `ExecStart`, or a devshell — instead of a mutable
# `pip install` into a venv.
#
# Nothing here re-packages mlx-lm from PyPI. nixpkgs ships it, keeps it current,
# and actually runs the parts of the upstream test suite that work without a GPU
# or network — all of which a hand-rolled `fetchPypi` + `doCheck = false` copy
# throws away.
#
# Usage:
#   pkgs.callPackage ./default.nix { }
#
#   # A version newer than your nixpkgs, or a fork — override, don't re-vendor:
#   pkgs.callPackage ./default.nix {
#     mlx-lm = pkgs.python3Packages.mlx-lm.overridePythonAttrs (old: rec {
#       version = "0.31.4";
#       src = old.src.override { tag = "v${version}"; hash = "sha256-..."; };
#     });
#   }
#
# Only runs on Apple Silicon (aarch64-darwin): MLX is Metal-backed. On other
# platforms the `mlx` dependency will not evaluate/build.

{
  pkgs ? import <nixpkgs> { },

  # Swap in your own build (newer release, fork, extra patches) without editing
  # this file — see the override example above.
  mlx-lm ? pkgs.python3Packages.mlx-lm,

  # nixpkgs treats sentencepiece as a *test* input only, but upstream declares
  # `transformers[sentencepiece]` as a runtime dep. Models that ship a
  # SentencePiece `tokenizer.model` and no fast `tokenizer.json` fail to load
  # without it, so keep it in the interpreter. Set to [ ] if you only ever serve
  # models with a fast tokenizer and want the smaller closure.
  extraPythonPackages ? [ pkgs.python3Packages.sentencepiece ],
}:

let
  # Invoke THIS interpreter rather than a bare `mlx_lm` console script, so the
  # module always resolves against exactly this closure.
  python = pkgs.python3.withPackages (_: [ mlx-lm ] ++ extraPythonPackages);
in

# `mlx_lm` ships an OpenAI-compatible HTTP server behind `python -m mlx_lm
# server`. Wrapping it here means callers get a stable `mlx-lm-server`
# executable and never touch pip/venv. All flags (`--model`, `--host`,
# `--port`, ...) pass straight through via "$@".
pkgs.writeShellScriptBin "mlx-lm-server" ''
  exec ${python}/bin/python -m mlx_lm server "$@"
''
