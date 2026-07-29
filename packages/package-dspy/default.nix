# Package the DSPy Python LLM framework for nixpkgs.
#
# Import this as a python-package callPackage, e.g. in an overlay:
#
#   final: prev: {
#     python3 = prev.python3.override {
#       packageOverrides = pfinal: pprev: {
#         dspy = pfinal.callPackage ./default.nix { };
#       };
#     };
#   }
#
# The things this file exists to demonstrate live in `postPatch`, the
# test-disabling blocks, and the DSPY_CACHEDIR export below — see README.md
# for the "why".
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
    # Update this hash when you bump `version` (nix-prefetch-url --unpack, or
    # let a failing build print the correct sha256-... for you).
    hash = "sha256-Mfl5ac367QnFgSHXTItBAQ0ksHR1mEKIjyptAbt/Bvc=";
  };

  # TRAP 1 — upstream ships an inconsistent version string.
  # The git tag is 3.1.3 but `dspy/__metadata__.py` and `pyproject.toml`
  # still say 3.1.2 inside the tagged tree. `buildPythonPackage` derives its
  # dist metadata from pyproject.toml, so without this patch the built wheel
  # is silently mislabelled 3.1.2 and any downstream `>=3.1.3` constraint or
  # import-time `dspy.__version__` check breaks. `--replace-fail` (not
  # `--replace`) makes the build FAIL LOUDLY the day upstream fixes their
  # strings, so this patch can never rot into a silent no-op.
  #
  # TRAP 2 — upstream pins some deps with `==`. nixpkgs carries slightly
  # different point releases of `asyncer`/`gepa`, so an exact pin makes the
  # runtime dependency check fail even though the newer version is compatible.
  # Loosen `==` to `>=` for the ones that drift.
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

  __darwinAllowLocalNetworking = true; # some tests spin up a local server

  nativeCheckInputs = [
    pytestCheckHook
    pytest-asyncio
    datamodel-code-generator
    litellm
    pillow
  ]
  ++ litellm.optional-dependencies.proxy;

  # TRAP 4 — DSPy picks its on-disk cache directory at *import* time, falling
  # back to $HOME/.dspy_cache; $HOME is not writable in the build sandbox, so
  # both the pytest run and `pythonImportsCheck` need it pointed elsewhere.
  #
  # This cannot be an `env` attribute. `env` values are handed to the builder
  # verbatim — no shell expansion, and `$(VAR)` is *make* syntax, which nothing
  # in a Nix build expands. `env.DSPY_CACHEDIR = "$(TMPDIR)/dummy"` therefore
  # sets the literal string `$(TMPDIR)/dummy`, and DSPy dutifully creates a
  # directory *named* `$(TMPDIR)` relative to the build cwd — nowhere near
  # $TMPDIR.
  #
  # $TMPDIR only exists inside the builder, so it has to be exported from a
  # hook. All phases share one shell, and `preBuild` runs before the check,
  # installCheck and preDist phases, so one export covers pytest and the
  # imports check alike.
  preBuild = ''
    export DSPY_CACHEDIR="$TMPDIR/dspy-cache"
  '';

  pythonImportsCheck = [
    "dspy"
  ];

  # TRAP 3 — most of DSPy's test suite talks to a real LLM (OpenAI/Anthropic),
  # opens outbound sockets, or hits network mime-type/PDF fixtures. None of
  # that works in a hermetic, network-less build sandbox, so it must be
  # disabled. Whole directories that are end-to-end LLM tests are dropped via
  # `disabledTestPaths`; individual network/LLM cases that live inside
  # otherwise-runnable files are dropped by name via `disabledTests`.
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
    description = "Framework for programming—not prompting—language models";
    homepage = "https://github.com/stanfordnlp/dspy";
    changelog = "https://github.com/stanfordnlp/dspy/releases/tag/${version}";
    license = lib.licenses.mit;
  };
}
