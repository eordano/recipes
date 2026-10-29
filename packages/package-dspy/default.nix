{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  fetchpatch,
  setuptools,
  wheel,
  anyio,
  cachetools,
  cloudpickle,
  diskcache,
  json-repair,
  litellm,
  numpy,
  openai,
  optuna,
  orjson,
  pydantic,
  regex,
  requests,
  tenacity,
  tqdm,
  gepa,
  anthropic,
  build,
  datamodel-code-generator,
  pillow,
  pre-commit,
  pytest,
  pytest-asyncio,
  pytest-mock,
  pytest-xdist,
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
  version = "3.4.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "stanfordnlp";
    repo = "dspy";
    tag = version;
    hash = "sha256-xs2RxQZeVJAry4GwMG6nuSPSSW7Wt3ZDPLKaFwS+oyg=";
  };

  patches = [
    (fetchpatch {
      name = "dspy-lazy-import-submodule-init.patch";
      url = "https://github.com/stanfordnlp/dspy/commit/3c584233b0933d7f28b97c73a80d8e3a871ba000.patch";
      hash = "sha256-Zg10xSI4n6mnE+CcPXlz5ajUGHqAU7afiIQIeUdME7U=";
    })
  ];

  postPatch = ''
    substituteInPlace dspy/__metadata__.py \
      --replace-fail '__version__="3.4.0b1"' '__version__="${version}"'
    substituteInPlace pyproject.toml \
      --replace-fail 'version="3.4.0b1"' 'version="${version}"'
    substituteInPlace pyproject.toml \
      --replace-fail 'gepa[dspy]==0.1.4' 'gepa[dspy]>=0.1.4'
  '';

  build-system = [
    setuptools
    wheel
  ];

  dependencies = [
    anyio
    cachetools
    cloudpickle
    diskcache
    gepa
    json-repair
    litellm
    openai
    orjson
    pydantic
    regex
    requests
    tenacity
    tqdm
  ];

  optional-dependencies = {
    anthropic = [
      anthropic
    ];
    dev = [
      build
      datamodel-code-generator
      litellm
      numpy
      pillow
      pre-commit
      pytest
      pytest-asyncio
      pytest-mock
      pytest-xdist
      ruff
    ];
    langchain = [
      langchain-core
    ];
    mcp = [
      mcp
    ];
    numpy = [
      numpy
    ];
    optuna = [
      optuna
    ];
    test_extras = [
      datasets
      langchain-core
      mcp
      numpy
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
    "tests/docs"
    "tests/predict"
    "tests/primitives"
    "tests/teleprompt"
    "tests/test_lm15_subtree_updater.py"
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
