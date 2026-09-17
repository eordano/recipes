{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  setuptools,
  wheel,
  anyio,
  asyncer,
  backoff,
  cachetools,
  cloudpickle,
  diskcache,
  joblib,
  json-repair,
  litellm,
  magicattr,
  numpy,
  openai,
  optuna,
  orjson,
  pydantic,
  regex,
  requests,
  rich,
  tenacity,
  tqdm,
  ujson,
  xxhash,
  gepa,
  anthropic,
  build,
  datamodel-code-generator,
  pillow,
  pre-commit,
  pytest,
  pytest-asyncio,
  pytest-mock,
  ruff,
  langchain-core,
  mcp,
  datasets,
  pandas,
  weaviate-client,
  pytestCheckHook,
}:
buildPythonPackage rec {
  pname = "dspy";
  version = "3.1.3";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "stanfordnlp";
    repo = "dspy";
    tag = version;
    hash = "sha256-Mfl5ac367QnFgSHXTItBAQ0ksHR1mEKIjyptAbt/Bvc=";
  };

  postPatch = ''
    substituteInPlace dspy/__metadata__.py \
      --replace-fail '__version__="3.1.2"' '__version__="${version}"'
    substituteInPlace pyproject.toml \
      --replace-fail 'version="3.1.2"' 'version="${version}"'
    substituteInPlace pyproject.toml \
      --replace-fail 'asyncer==0.0.8' 'asyncer>=0.0.8' \
      --replace-fail 'gepa[dspy]==0.0.26' 'gepa[dspy]>=0.0.26'
  '';

  build-system = [
    setuptools
    wheel
  ];

  dependencies = [
    anyio
    asyncer
    backoff
    cachetools
    cloudpickle
    diskcache
    gepa
    joblib
    json-repair
    litellm
    magicattr
    numpy
    openai
    optuna
    orjson
    pydantic
    regex
    requests
    rich
    tenacity
    tqdm
    ujson
    xxhash
  ];

  optional-dependencies = {
    anthropic = [
      anthropic
    ];
    dev = [
      build
      datamodel-code-generator
      litellm
      pillow
      pre-commit
      pytest
      pytest-asyncio
      pytest-mock
      ruff
    ];
    langchain = [
      langchain-core
    ];
    mcp = [
      mcp
    ];
    test_extras = [
      datasets
      langchain-core
      mcp
      optuna
      pandas
    ];
    weaviate = [
      weaviate-client
    ];
  };

  __darwinAllowLocalNetworking = true;

  nativeCheckInputs = [
    pytestCheckHook
    pytest-asyncio
    datamodel-code-generator
    litellm
    pillow
  ]
  ++ litellm.optional-dependencies.proxy;

  preBuild = ''
    export DSPY_CACHEDIR="$TMPDIR/dspy-cache"
  '';

  pythonImportsCheck = [
    "dspy"
  ];

  disabledTestPaths = [
    "tests/predict/test_rlm.py"
    "tests/adapters"
    "tests/clients"
    "tests/predict"
    "tests/primitives"
    "tests/teleprompt"
  ];

  disabledTests = [
    "test_pdf_url_support"
    "test_different_mime_types"
    "test_mime_type_from_response_headers"
    "test_pdf_from_file"
    "test_image_input_formats"
    "test_predictor_save_load"
    "test_chat_lms_can_be_queried"
    "test_dspy_cache"
    "test_text_lms_can_be_queried"
    "test_lm_calls_support_callables"
    "test_lm_calls_support_pydantic_models"
    "test_responses_api"
    "test_responses_api_tool_calls"
    "test_streamify_yields_expected_response_chunks"
    "test_streaming_response_yields_expected_response_chunks"
    "test_dspy_context_with_dspy_parallel"
    "test_dspy_context_with_async_task_group"
  ];

  meta = {
    description = "Framework for programming--not prompting--language models";
    homepage = "https://github.com/stanfordnlp/dspy";
    changelog = "https://github.com/stanfordnlp/dspy/releases/tag/${version}";
    license = lib.licenses.mit;
  };
}
