_final: prev:
let
  typerSrc = prev.fetchFromGitHub {
    owner = "fastapi";
    repo = "typer";
    tag = "0.27.2";
    hash = "sha256-vBHSJoyIQawkqqhbPJGKzPjBPm42OR/Ref/k6XFJTi8=";
  };
in
{
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (pfinal: pprev: {

      typer = pprev.typer.overridePythonAttrs (_old: rec {
        pname = "typer";
        version = "0.27.2";
        src = typerSrc;
        dependencies = [
          pfinal.shellingham
          pfinal.rich
          pfinal.annotated-doc
        ];
        optional-dependencies = { };
        doCheck = false;
      });

      typer-slim = pfinal.typer;

      huggingface-hub = pprev.huggingface-hub.overridePythonAttrs (_old: rec {
        version = "1.33.0";
        src = prev.fetchFromGitHub {
          owner = "huggingface";
          repo = "huggingface_hub";
          tag = "v${version}";
          hash = "sha256-fs50qE6UUDDE5vi/ahGpZnMo1F7T1a76RJfYVcltS9o=";
        };
        dependencies = [
          pfinal.click
          pfinal.filelock
          pfinal.fsspec
          pfinal.hf-xet
          pfinal.httpx
          pfinal.packaging
          pfinal.pyyaml
          pfinal.tqdm
          pfinal.typing-extensions
        ];
        pythonRelaxDeps = [ "click" ];
        doCheck = false;
      });

      accelerate = pprev.accelerate.overridePythonAttrs (_: {
        doCheck = false;
      });

      sentence-transformers = pprev.sentence-transformers.overridePythonAttrs (_: {
        doCheck = false;
      });

      transformers = pprev.transformers.overridePythonAttrs (_old: rec {
        version = "5.18.0";
        src = prev.fetchFromGitHub {
          owner = "huggingface";
          repo = "transformers";
          tag = "v${version}";
          hash = "sha256-+Vj9YXiLU60Jb4KC+Azaqx7l0Odin9QfkZfkgyCiGT8=";
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
