{
  pkgs ? import <nixpkgs> { },

  mlx-lm ? pkgs.python3Packages.mlx-lm,

  extraPythonPackages ? [ pkgs.python3Packages.sentencepiece ],
}:

let
  inherit (pkgs) python3Packages;

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

    pythonRemoveDeps = [ "opencv-python" ];

    postPatch =
      let
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

  pythonEnv = pkgs.python3.withPackages (_: [ mlx-vlm ] ++ extraPythonPackages);

  mlx-vlm-server = pkgs.writeShellScriptBin "mlx-vlm-server" ''
    exec ${pythonEnv}/bin/python -m mlx_vlm.server "$@"
  '';
in
{
  inherit mlx-lm mlx-vlm mlx-vlm-server;
}
