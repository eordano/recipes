# Packaging an upstream Python tool (GEPA) whose pyproject.toml hardcodes a
# stale version string out of sync with its own git tag.
#
# Two reusable techniques live here:
#
#   1. postPatch + substituteInPlace --replace-fail
#      The repo is tagged `v0.1.0` but its committed pyproject.toml still says
#      `version="0.0.27"`. buildPythonPackage derives the wheel version from
#      pyproject, so the build would produce a `0.0.27` wheel even though we
#      fetched the `v0.1.0` tag — and any downstream `>=0.1.0` constraint would
#      then fail to resolve. Rewrite the string at build time. Use
#      `--replace-fail` (not plain `--replace`) so the build errors loudly the
#      day upstream fixes their pyproject and the literal disappears, instead of
#      silently no-op'ing and shipping a wrong version forever.
#
#   2. Heavy deps go in optional-dependencies, not dependencies.
#      The core library is lean. LLM plumbing (litellm), dataset handling
#      (datasets), and experiment trackers (mlflow, wandb) are only needed by
#      users who opt in. Keeping them out of `dependencies` means importing the
#      package doesn't drag a giant closure (and its own frequent breakages)
#      into every consumer. Downstreams that need them ask for `gepa[full]` or
#      `gepa[dspy]`.
#
# Drop this in a python-modules overlay:
#
#   _prev: self: _super: {
#     gepa = self.callPackage ./gepa.nix { };
#   }
#
# and add that overlay to `pythonPackagesExtensions`.

{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  setuptools,
  wheel,
  litellm,
  datasets,
  mlflow,
  wandb,
  tqdm,
}:

buildPythonPackage rec {
  pname = "gepa";
  version = "0.1.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "gepa-ai";
    repo = "gepa";
    tag = "v${version}";
    # nix-prefetch-github gepa-ai gepa --rev v0.1.0
    hash = "sha256-W0wW7dV8jMgeem8HjBYxcaL1VA9zBwMbePqLSsQe8qQ=";
  };

  # Upstream's committed pyproject.toml lags its own git tag. Realign the
  # declared version with the tag we actually fetched. --replace-fail makes the
  # build fail (rather than silently pass) once upstream fixes this and the
  # literal string no longer exists to match.
  postPatch = ''
    substituteInPlace pyproject.toml \
      --replace-fail 'version="0.0.27"' 'version="${version}"'
  '';

  build-system = [
    setuptools
    wheel
  ];

  # Keep the core install lean; only pull the heavy LLM / tracking stack when a
  # consumer explicitly asks for it via an extra.
  optional-dependencies = {
    full = [
      litellm
      datasets
      mlflow
      wandb
      tqdm
    ];
    dspy = [
      litellm
      datasets
      tqdm
    ];
  };

  pythonImportsCheck = [
    "gepa"
  ];

  # Upstream test suite reaches for live LLM providers; keep it off in the
  # sandbox and rely on pythonImportsCheck for a smoke test.
  doCheck = false;

  meta = {
    description = "Framework for optimizing textual system components using LLM-based reflection and Pareto-efficient evolutionary search";
    homepage = "https://github.com/gepa-ai/gepa";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ ];
  };
}
