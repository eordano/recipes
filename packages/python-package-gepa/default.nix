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
    hash = "sha256-W0wW7dV8jMgeem8HjBYxcaL1VA9zBwMbePqLSsQe8qQ=";
  };

  postPatch = ''
    substituteInPlace pyproject.toml \
      --replace-fail 'version="0.0.27"' 'version="${version}"'
  '';

  build-system = [
    setuptools
    wheel
  ];

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

  doCheck = false;

  meta = {
    description = "Framework for optimizing textual system components using LLM-based reflection and Pareto-efficient evolutionary search";
    homepage = "https://github.com/gepa-ai/gepa";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ ];
  };
}
