# Package mlx-vlm on Nix Without the Torch/OpenCV Chain

Apple's [`mlx-vlm`](https://github.com/Blaizzy/mlx-vlm) runs vision-language
models on Apple Silicon via MLX. Packaging it for Nix is mostly routine
`buildPythonPackage` work — except for one trap that, if you don't handle it,
drags a huge, mostly-useless dependency chain into the closure.

## The problem

Recent versions of `transformers` resolve an **`AutoVideoProcessor`** whenever a
processor is constructed for a VLM. Building that video processor imports
**torch**, **torchvision**, and (transitively) **opencv-python**. For
image-plus-text inference you never process a single frame of video — but the
import happens anyway, at model-load time, purely as a side effect of
`AutoProcessor.from_pretrained(...)`.

On Nix this is worse than a fat wheel: `torch` + `torchvision` from PyPI want
their own binary provenance and CUDA-shaped assumptions, and `opencv-python`
fights with the C++ `opencv4` that nixpkgs already ships. You end up either
patching a wheel or building a second OpenCV.

## The insight

You don't need the video processor to exist — you need it to *not run*. So
monkey-patch it out at **build time**, surgically, around the one call that
triggers it:

1. Wrap the single `processor = AutoProcessor.from_pretrained(...)` line in
   `mlx_vlm/utils.py`.
2. Just before it, replace
   `AutoVideoProcessor.from_pretrained` with a no-op that returns `None`, and
   relax `ProcessorMixin.check_argument_for_proper_class` so it accepts that
   `None` instead of type-checking the absent processor.
3. Immediately after the call, **restore both originals**, so nothing else in
   the running process is affected.

With the video path neutered, the torch / torchvision / opencv-python chain is
never imported, and you can supply `cv2` from the nixpkgs `opencv4` C++ build
while stripping the PyPI `opencv-python` pin (`pythonRemoveDeps`).

## Why the patch is deliberately narrow

The replacement targets exactly one source line via `substituteInPlace
... --replace-fail`. Two reasons:

- **Fail loud on upstream drift.** `--replace-fail` errors the build if that
  line ever changes shape in a new `mlx-vlm` release, instead of silently
  patching nothing and leaving you to discover the torch import at runtime.
- **Easy to re-audit.** A one-line surgical wrap is trivial to eyeball after a
  version bump.

### The indentation gotcha

The replaced statement lives inside an indented function body. Every injected
line *after the first* therefore carries a hard-coded four-space indent in the
Nix string — the first line inherits the original statement's indentation (it
takes its place), the rest must supply their own. Drop that indentation and you
get a Python `IndentationError` at import time, not at build time.

## Usage

```nix
# Simplest: let callPackage wire the arguments.
mlx-vlm = pkgs.callPackage ./default.nix { };

# If you need an mlx-lm other than the one nixpkgs ships, override that
# derivation rather than re-packaging it from PyPI:
mlx-vlm = import ./default.nix {
  inherit (pkgs) python3Packages;
  mlx-lm = pkgs.python3Packages.mlx-lm.overridePythonAttrs (old: rec {
    version = "0.31.4";
    src = old.src.override {
      tag = "v${version}";
      hash = "sha256-...";
    };
  });
};
```

### Options

| Argument         | Default                                   | Purpose |
| ---------------- | ----------------------------------------- | ------- |
| `python3Packages`| —                                         | The Python package set to build against. |
| `mlx-lm`         | `python3Packages.mlx-lm`                   | mlx-vlm's core runtime; pass an `overridePythonAttrs` of the nixpkgs package if you need a different release. |
| `version`        | `"0.4.2"`                                  | PyPI release to fetch. |
| `hash`           | sha256 for 0.4.2                           | Override when you bump `version` (run the build once, copy the expected hash). |

To run the bundled OpenAI-compatible server, wrap it:

```nix
pkgs.writeShellScriptBin "mlx-vlm-server" ''
  exec ${pkgs.python3.withPackages (_: [ mlx-vlm ])}/bin/python -m mlx_vlm.server "$@"
''
```

## Caveats

- **Video inference is gone by design.** This package is for image + text.
  If you need video, don't apply this patch — take the torch/torchvision cost.
- **Version-coupled patch.** The wrapped line is specific to the packaged
  `mlx-vlm` version. On a bump, expect `--replace-fail` to catch a changed line;
  re-point `old`/`new` at the new call site.
- **`opencv4`, not `opencv-python`.** The nixpkgs C++ OpenCV satisfies the `cv2`
  import; the `pythonRemoveDeps = [ "opencv-python" ]` line keeps the PyPI pin
  from re-introducing the wheel.
- **Apple Silicon only.** MLX targets Metal; this builds and runs on macOS
  aarch64.
