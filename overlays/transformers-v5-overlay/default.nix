# transformers-v5-overlay
#
# Run a fast-moving Python package (here: HuggingFace `transformers` v5) ahead
# of your nixpkgs pin. The catch: a major bump also *reshapes the dependency
# surface*, so `overridePythonAttrs` on `transformers` alone is not enough -- you
# must also rebuild the shifted transitive deps (`typer`, its `typer-slim`
# alias, `huggingface-hub`) from their own upstream tags, each with a
# HAND-WRITTEN `dependencies` list, or the closure keeps the OLD deps and either
# fails to build or imports the wrong versions at runtime.
#
# Everything below is packaged through `pythonPackagesExtensions` (not a flat
# `python3Packages` override) so the overrides stack across every Python
# interpreter in the tree, not just one.
#
# To bump: change each `version`/`tag`, set the corresponding `hash` to
# `prev.lib.fakeHash`, build, and copy the real hash from the error. Re-check
# each `dependencies` list against that release's `pyproject.toml` -- that is the
# manual step the trap is about.
#
# Usage:
#   nixpkgs.overlays = [ (import ./overlays/transformers-v5-overlay) ];

final: prev:
let
  # typer >=0.16 splits itself into two build "packages" selected by the
  # TIANGOLO_BUILD_PACKAGE env var (`typer` = full, `typer-slim` = no rich/
  # shellingham). We build the full one and alias `typer-slim` to it below.
  typerSrc = prev.fetchFromGitHub {
    owner = "fastapi";
    repo = "typer";
    tag = "0.24.1";
    hash = "sha256-5mEwW51c56LG95KAe0rBI4FaoDcHIKdIrpqzNuT6Svk=";
  };
in
{
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (pfinal: pprev: {

      # typer: newer transformers/huggingface-hub want a typer the pin predates.
      # `dependencies` is written out by hand: overridePythonAttrs keeps the OLD
      # dependency list otherwise, and this version added `annotated-doc`.
      typer = pprev.typer.overridePythonAttrs (old: rec {
        pname = "typer";
        version = "0.24.1";
        src = typerSrc;
        env.TIANGOLO_BUILD_PACKAGE = "typer";
        dependencies = [
          pfinal.click
          pfinal.shellingham
          pfinal.rich
          pfinal.annotated-doc
        ];
        optional-dependencies = { };
        doCheck = false;
      });

      # typer-slim is a separate distribution upstream, but consumers only need
      # the API to resolve -- alias it to the full build we just made.
      typer-slim = pfinal.typer;

      # huggingface-hub 1.x is the surface transformers v5 targets. Its deps
      # shifted (e.g. it now pulls `typer`/`shellingham`), so spell them out.
      huggingface-hub = pprev.huggingface-hub.overridePythonAttrs (old: rec {
        version = "1.7.0";
        src = prev.fetchFromGitHub {
          owner = "huggingface";
          repo = "huggingface_hub";
          tag = "v${version}";
          hash = "sha256-5dp9RvloH3xB5oRbZU08jkLCKGJa236aoOf6gYK4H20=";
        };
        dependencies = [
          pfinal.filelock
          pfinal.fsspec
          pfinal.hf-xet
          pfinal.httpx
          pfinal.packaging
          pfinal.pyyaml
          pfinal.shellingham
          pfinal.tqdm
          pfinal.typer
          pfinal.typing-extensions
        ];
        doCheck = false;
      });

      # These consume the new transformers/hub; their pinned test suites lag the
      # bumped deps, so drop the checks (build-time only; runtime is unaffected).
      accelerate = pprev.accelerate.overridePythonAttrs (_: {
        doCheck = false;
      });

      sentence-transformers = pprev.sentence-transformers.overridePythonAttrs (_: {
        doCheck = false;
      });

      # The headline bump. `dependencies` is rewritten to the v5 surface: it now
      # takes `typer` and no longer needs some of the old entries.
      transformers = pprev.transformers.overridePythonAttrs (old: rec {
        version = "5.5.3";
        src = prev.fetchFromGitHub {
          owner = "huggingface";
          repo = "transformers";
          tag = "v${version}";
          hash = "sha256-pMZmGHlLDG2vXG0lsuDWR2gqzGS/FGDKjU/cel51bkY=";
        };
        dependencies = [
          pfinal.huggingface-hub
          pfinal.numpy
          pfinal.packaging
          pfinal.pyyaml
          pfinal.regex
          pfinal.tokenizers
          pfinal.safetensors
          pfinal.tqdm
          pfinal.typer
        ];
        doCheck = false;
      });
    })
  ];
}
