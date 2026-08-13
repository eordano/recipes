# mlx-lm -- use Apple's MLX language-model package from nixpkgs, and bump it past
# your channel with an override when you need a newer release.
#
# nixpkgs ships `python3Packages.mlx-lm` (Metal-backed, Apple Silicon only). Reach
# for that first: it tracks upstream releases, resolves the full dependency
# closure, and runs the parts of the upstream test suite that work without a GPU
# or network. Re-packaging it from PyPI by hand throws all of that away and leaves
# you hand-mirroring `pyproject.toml` forever -- miss a new dep and the build
# still succeeds, then `ImportError`s at runtime.
#
# When you genuinely need a version newer than your channel (or a fork), override
# the nixpkgs derivation instead of re-vendoring -- you keep its dependency list,
# its patches, and its test config, and change only the source. Two traps bite on
# that override path, both PyPI-normalization lessons worth keeping:
#
#   1. fetchPypi.pname must be the UNDERSCORE distribution name (mlx_lm), not the
#      hyphenated project name (mlx-lm). PyPI names the sdist tarball after the
#      underscore form; the hyphen form 404s and surfaces as a hash mismatch that
#      sends you hunting for the "right hash" when the wrong URL is the real
#      problem. This is a general PyPI rule, not specific to this package.
#   2. doCheck must be false for a hand-supplied PyPI src: the upstream suite wants
#      a GPU (Apple Metal) and downloads model weights, so it cannot run in the
#      Nix sandbox. (nixpkgs' own build avoids the blanket switch-off via a precise
#      `disabledTestPaths` list -- another reason to prefer it.)
#
# Usage (callPackage):
#   mlx-lm = pkgs.callPackage ./default.nix { };
#
#   # A version newer than your nixpkgs, or a fork -- override, don't re-vendor:
#   mlx-lm = pkgs.callPackage ./default.nix {
#     mlx-lm = pkgs.python3Packages.mlx-lm.overridePythonAttrs (old: rec {
#       version = "0.31.4";
#       src = old.src.override { tag = "v${version}"; hash = "sha256-..."; };
#     });
#   };
#
# Apple Silicon only (aarch64-darwin): MLX is Metal-backed; the `mlx` dependency
# does not evaluate/build on other platforms.

{
  pkgs ? import <nixpkgs> { },

  # Start from nixpkgs' package. To ship a newer release or a fork, override it
  # here instead of re-vendoring from PyPI -- see the examples above / in README.
  mlx-lm ? pkgs.python3Packages.mlx-lm,
}:

mlx-lm
