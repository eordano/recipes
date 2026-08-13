# Add a torch-free VLM processor load to nixpkgs' mlx-vlm.
#
# nixpkgs already ships `python3Packages.mlx-vlm`, so there is nothing to build
# from PyPI here. The one reusable trick worth keeping is a build-time source
# patch (`postPatch`) that stops model loading from importing torch/torchvision
# through transformers' `AutoVideoProcessor`. We layer it onto the existing
# derivation with `overridePythonAttrs` instead of re-vendoring the whole
# package (which only earns a permanent version lag and a hand-copied
# dependency list). See README.md for the full why.
#
# Usage (callPackage-style):
#   mlx-vlm = pkgs.callPackage ./default.nix { };
# or pin a specific interpreter's package set:
#   mlx-vlm = pkgs.callPackage ./default.nix {
#     python3Packages = pkgs.python311Packages;
#   };

{ python3Packages }:

python3Packages.mlx-vlm.overridePythonAttrs (old: {
  # --- The load-bearing trap -------------------------------------------------
  # transformers resolves an `AutoVideoProcessor` whenever a processor is built
  # for a VLM. Constructing that video processor imports torch / torchvision.
  # Image + text inference never touches video, so neutralise
  # `AutoVideoProcessor.from_pretrained` for the duration of the single
  # `AutoProcessor.from_pretrained(...)` call, then restore it.
  #
  # We append to any existing postPatch and wrap only that one line, so the
  # patch is surgical and self-reverting; `--replace-fail` makes the build fail
  # loudly if a future mlx-vlm release rewrites the call site instead of
  # silently no-op'ing.
  #
  # NOTE the leading four-space indentation on every injected line *after* the
  # first: the replaced statement lives inside an indented function body, so the
  # injected statements must carry that indentation to stay valid Python.
  postPatch =
    (old.postPatch or "")
    + (
      let
        call = "processor = AutoProcessor.from_pretrained(model_path, use_fast=True, **kwargs)";
        wrapped = builtins.concatStringsSep "\n" [
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
            '${call}' \
            '${wrapped}'
      ''
    );

  meta = (old.meta or { }) // {
    description = "Apple MLX vision-language inference (image + text), patched to load models without importing torch/torchvision";
  };
})
