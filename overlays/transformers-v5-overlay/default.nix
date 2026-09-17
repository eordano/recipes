_final: prev:
let
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

      typer = pprev.typer.overridePythonAttrs (_old: rec {
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

      typer-slim = pfinal.typer;

      huggingface-hub = pprev.huggingface-hub.overridePythonAttrs (_old: rec {
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

      accelerate = pprev.accelerate.overridePythonAttrs (_: {
        doCheck = false;
      });

      sentence-transformers = pprev.sentence-transformers.overridePythonAttrs (_: {
        doCheck = false;
      });

      transformers = pprev.transformers.overridePythonAttrs (_old: rec {
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
