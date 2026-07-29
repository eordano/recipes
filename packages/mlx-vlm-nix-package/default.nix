# Packaging Apple MLX's vision-language library (mlx-vlm) for Nix.
#
# The interesting part is the `postPatch` block: it monkey-patches
# transformers' AutoVideoProcessor at *build time* so that loading a model
# never tries to construct a video processor. That single edit lets us drop
# the entire torch / torchvision / opencv-python dependency chain that the
# video path would otherwise drag in. See README.md for the full why.
#
# Usage (called with the standard buildPythonPackage convention):
#
#   mlx-vlm = pkgs.callPackage ./default.nix { };
#   # or, if you need an mlx-lm other than the one nixpkgs ships:
#   mlx-vlm = import ./default.nix {
#     inherit (pkgs) python3Packages;
#     mlx-lm = python3Packages.mlx-lm.overridePythonAttrs (old: { /* ... */ });
#   };

{
  python3Packages,
  # mlx-vlm depends on mlx-lm, which nixpkgs ships as python3Packages.mlx-lm.
  # Override that derivation and pass it here if you need a different build;
  # re-packaging it from PyPI just to change a version is not worth the
  # hand-maintained dependency list and hash.
  mlx-lm ? python3Packages.mlx-lm,
  version ? "0.4.2",
  # sha256 of the PyPI sdist for the given version. Override when you bump.
  hash ? "sha256-MchLQyHI8XzssEV/oY1cBomCCmavGRkm0kDn35dWRT4=",
}:

python3Packages.buildPythonPackage rec {
  pname = "mlx-vlm";
  inherit version;
  pyproject = true;

  src = python3Packages.fetchPypi {
    pname = "mlx_vlm";
    inherit version hash;
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
    # opencv4 (the nixpkgs C++ build) satisfies mlx-vlm's cv2 import without
    # pulling opencv-python (which would want a wheel + its own deps).
    opencv4
  ];

  # Upstream pins opencv-python from PyPI; we satisfy cv2 via nixpkgs opencv4
  # instead, so strip the PyPI pin from the metadata.
  pythonRemoveDeps = [ "opencv-python" ];

  # --- The load-bearing trap -------------------------------------------------
  # transformers >= 4.5x resolves an AutoVideoProcessor whenever a processor is
  # built for a VLM. Constructing that video processor imports torch /
  # torchvision (and, transitively, opencv-python). For image + text inference
  # we never touch video, so we neutralise AutoVideoProcessor.from_pretrained
  # for the duration of the AutoProcessor call, then restore it.
  #
  # We wrap only the single `AutoProcessor.from_pretrained(...)` line so the
  # patch is surgical and easy to re-verify after an upstream bump. If a future
  # mlx-vlm release changes that line, `--replace-fail` makes the build fail
  # loudly instead of silently no-op'ing.
  #
  # NOTE the leading four-space indentation baked into every line *after* the
  # first: the replaced statement lives inside an indented function body, so the
  # injected statements must carry that indentation to stay syntactically valid.
  postPatch =
    let
      old = "processor = AutoProcessor.from_pretrained(model_path, use_fast=True, **kwargs)";
      new = builtins.concatStringsSep "\n" [
        "from transformers.models.auto import video_processing_auto as _vpa"
        "    from transformers import processing_utils as _pu"
        "    _orig_vp = _vpa.AutoVideoProcessor.from_pretrained"
        "    _orig_check = _pu.ProcessorMixin.check_argument_for_proper_class"
        # Make AutoVideoProcessor.from_pretrained a no-op returning None ...
        "    _vpa.AutoVideoProcessor.from_pretrained = classmethod(lambda cls, *a, **kw: None)"
        # ... and let ProcessorMixin accept that None where it would otherwise
        # type-check the (now absent) video processor.
        "    def _skip_none_check(self, name, arg):"
        "        if arg is None: return type(None)"
        "        return _orig_check(self, name, arg)"
        "    _pu.ProcessorMixin.check_argument_for_proper_class = _skip_none_check"
        "    processor = AutoProcessor.from_pretrained(model_path, use_fast=True, **kwargs)"
        # Restore the originals so nothing else in the process is affected.
        "    _vpa.AutoVideoProcessor.from_pretrained = _orig_vp"
        "    _pu.ProcessorMixin.check_argument_for_proper_class = _orig_check"
      ];
    in
    ''
      substituteInPlace mlx_vlm/utils.py \
        --replace-fail \
          '${old}' \
          '${new}'
    '';

  # No test suite worth running at build time (needs model weights + Metal).
  doCheck = false;

  meta = {
    description = "Apple MLX vision-language model inference (image + text), packaged for Nix without the torch/torchvision/opencv-python chain";
    homepage = "https://github.com/Blaizzy/mlx-vlm";
  };
}
