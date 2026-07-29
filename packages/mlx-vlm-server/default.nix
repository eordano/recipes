# mlx-vlm-server — a standalone Nix build of Apple MLX's vision-language
# inference server, with two build-time source patches that make text-only
# VLMs and reasoning models actually usable.
#
# What you get (import this file, then build one of the attrs it returns):
#
#   nix-build -A mlx-vlm-server   # OpenAI-compatible server binary
#   nix-build -A mlx-vlm          # the Python package (patched)
#   nix-build -A mlx-lm           # the text-only dependency
#
# The reusable value is `mlx-vlm` below: its `postPatch` (a) neuters
# torchvision video processing so text-only / image-only VLMs load without a
# heavyweight PyTorch stack, and (b) runs ./thinking-patch.py to split
# <think>…</think> reasoning into a separate `reasoning_content` field and to
# recover a chat_template that community quantizations strip.
#
# The text-only dependency, mlx-lm, is NOT re-packaged here: nixpkgs ships
# `python3Packages.mlx-lm`, tracks upstream, and runs the sandbox-safe half of
# its test suite. Pass `mlx-lm` if you need a different build — override the
# nixpkgs derivation rather than re-vendoring a fetchPypi copy.
#
# mlx-vlm itself IS built here, because the two source patches are the recipe.
# It is pinned by hash and builds offline once fetched — Apple Silicon only
# (mlx is Metal-backed), so build on nix-darwin / an aarch64-darwin box.
#
# Usage from a flake:
#   let mlx = import ./packages/mlx-vlm-server { inherit pkgs; };
#   in  mlx.mlx-vlm-server
#
# Then run:  mlx-vlm-server --model <hf-repo-or-path> --host 127.0.0.1 --port 8080

{
  pkgs ? import <nixpkgs> { },

  # Text-only MLX inference; mlx-vlm builds on top of it.
  mlx-lm ? pkgs.python3Packages.mlx-lm,

  # nixpkgs keeps sentencepiece as a check input only, while upstream mlx-lm
  # declares transformers[sentencepiece]. Without it, models whose tokenizer is
  # a SentencePiece `tokenizer.model` with no fast `tokenizer.json` fail to
  # load. Set to [ ] for a smaller closure if none of your models need it.
  extraPythonPackages ? [ pkgs.python3Packages.sentencepiece ],
}:

let
  python3Packages = pkgs.python3Packages;

  # ---------------------------------------------------------------------------
  # mlx-vlm — vision-language inference + an OpenAI-compatible server.
  #
  # The two source patches in postPatch are the whole point of this recipe:
  #
  #  1. Video-processing bypass (the substituteInPlace on utils.py).
  #     transformers' AutoProcessor eagerly constructs an AutoVideoProcessor,
  #     which drags in torchvision. Many capable VLMs are text/image-only and
  #     you do not want a torch+torchvision closure just to load them. The
  #     patch monkeypatches AutoVideoProcessor.from_pretrained to return None
  #     for the duration of the AutoProcessor call, and relaxes the class check
  #     that would otherwise reject the None video processor — then restores
  #     both originals. Result: the processor loads, video is simply absent.
  #
  #  2. Reasoning + chat-template fixes (./thinking-patch.py), applied to
  #     server.py and prompt_utils.py. See that file for the details; in short
  #     it splits <think>…</think> into `reasoning_content` (streaming and
  #     non-streaming) and re-hydrates a chat_template that quantized repos drop.
  # ---------------------------------------------------------------------------
  mlx-vlm = python3Packages.buildPythonPackage rec {
    pname = "mlx-vlm";
    version = "0.4.2";
    pyproject = true;

    src = python3Packages.fetchPypi {
      pname = "mlx_vlm";
      inherit version;
      hash = "sha256-MchLQyHI8XzssEV/oY1cBomCCmavGRkm0kDn35dWRT4=";
    };

    build-system = [ python3Packages.setuptools ];

    dependencies = with python3Packages; [
      mlx-lm
      mlx
      numpy
      transformers
      pillow
      requests
      fastapi
      uvicorn
      tqdm
      datasets
      soundfile
      miniaudio
      opencv4
    ];

    # nixpkgs ships opencv as `opencv4`, not the PyPI `opencv-python` wheel;
    # drop the wheel dep so the metadata check passes.
    pythonRemoveDeps = [ "opencv-python" ];

    postPatch =
      let
        # The eager AutoProcessor call, replaced by a torchvision-free version
        # that temporarily disables the video processor. The leading indent on
        # every line after the first matches the original call site's block.
        old = "processor = AutoProcessor.from_pretrained(model_path, use_fast=True, **kwargs)";
        new = builtins.concatStringsSep "\n" [
          "from transformers.models.auto import video_processing_auto as _vpa"
          "    from transformers import processing_utils as _pu"
          "    _orig_vp = _vpa.AutoVideoProcessor.from_pretrained"
          "    _orig_check = _pu.ProcessorMixin.check_argument_for_proper_class"
          "    _vpa.AutoVideoProcessor.from_pretrained = classmethod(lambda cls, *a, **kw: None)"
          "    def _skip_none_check(self, name, arg):"
          "        if arg is None: return type(None)"
          "        return _orig_check(self, name, arg)"
          "    _pu.ProcessorMixin.check_argument_for_proper_class = _skip_none_check"
          "    processor = AutoProcessor.from_pretrained(model_path, use_fast=True, **kwargs)"
          "    _vpa.AutoVideoProcessor.from_pretrained = _orig_vp"
          "    _pu.ProcessorMixin.check_argument_for_proper_class = _orig_check"
        ];
        thinkingPatch = ./thinking-patch.py;
      in
      ''
        substituteInPlace mlx_vlm/utils.py \
          --replace-fail \
            '${old}' \
            '${new}'

        ${python3Packages.python.interpreter} ${thinkingPatch}
      '';

    doCheck = false;
  };

  # ---------------------------------------------------------------------------
  # mlx-vlm-server — a plain, on-PATH binary. `python -m mlx_vlm.server`
  # wrapped so nothing needs to know about the Python environment. All CLI
  # args pass straight through to the module (--model, --host, --port, …).
  # ---------------------------------------------------------------------------
  pythonEnv = pkgs.python3.withPackages (_: [ mlx-vlm ] ++ extraPythonPackages);

  mlx-vlm-server = pkgs.writeShellScriptBin "mlx-vlm-server" ''
    exec ${pythonEnv}/bin/python -m mlx_vlm.server "$@"
  '';
in
{
  inherit mlx-lm mlx-vlm mlx-vlm-server;
}
