{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  setuptools,
  wheel,
  litellm,
  cloudpickle,
  datasets,
  mlflow,
  wandb,
  tqdm,
}:

buildPythonPackage rec {
  pname = "gepa";
  version = "0.1.4";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "gepa-ai";
    repo = "gepa";
    tag = "v${version}";
    hash = "sha256-s9/Vjzd5/JFuMgT9huiURu6I8qlxsRagi4h6v+75IxM=";
  };

  postPatch = ''
    substituteInPlace pyproject.toml \
      --replace-fail 'version="0.1.3"' 'version="${version}"'
  '';

  build-system = [
    setuptools
    wheel
  ];

  optional-dependencies = {
    full = [
      litellm
      tqdm
      cloudpickle
      datasets
      mlflow
      wandb
    ];
    dspy = [ ];
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
