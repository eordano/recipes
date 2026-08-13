# TECHNIQUE DEMO -- realigning a buildPythonPackage version string with its git
# tag via `substituteInPlace ... --replace-fail`, using GEPA's historical
# v0.1.0 drift as the worked example.
#
# DO NOT vendor this to get GEPA. nixpkgs now ships `python3Packages.gepa`
# (0.1.3 at time of writing, built from tag v0.1.3) -- use that. This file is
# frozen on the older v0.1.0 tag *on purpose*, because that tag's committed
# pyproject.toml still declared `version="0.0.27"` and so makes a clean example
# of the version-string-drift problem below. Read it as a template for the next
# hand-packaged buildPythonPackage you hit with the same issue.
#
# Two reusable techniques live here:
#
#   1. postPatch + substituteInPlace --replace-fail
#      The repo is tagged `v0.1.0` but its committed pyproject.toml still says
#      `version="0.0.27"`. buildPythonPackage derives the wheel version from
#      pyproject, so the build would produce a `0.0.27` wheel even though we
#      fetched the `v0.1.0` tag -- and any downstream `>=0.1.0` constraint would
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
# For a package that genuinely isn't in nixpkgs, the same shape drops into a
# python-modules overlay:
#
#   _prev: self: _super: {
#     yourpkg = self.callPackage ./yourpkg.nix { };
#   }
#
# and gets added to `pythonPackagesExtensions`. (You would not do this for
# `gepa` itself -- nixpkgs already provides it.)

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
