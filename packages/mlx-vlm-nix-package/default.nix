{ python3Packages }:

python3Packages.mlx-vlm.overridePythonAttrs (old: {
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
          "    _vpa.AutoVideoProcessor.from_pretrained = classmethod(lambda cls, *a, **kw: None)"
          "    def _skip_none_check(self, name, arg):"
          "        if arg is None: return type(None)"
          "        return _orig_check(self, name, arg)"
          "    _pu.ProcessorMixin.check_argument_for_proper_class = _skip_none_check"
          "    processor = AutoProcessor.from_pretrained(model_path, use_fast=True, **kwargs)"
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
