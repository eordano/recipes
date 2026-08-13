# Load an MLX VLM Without Importing Torch/Torchvision

Apple's [`mlx-vlm`](https://github.com/Blaizzy/mlx-vlm) runs vision-language
models on Apple Silicon via MLX. `nixpkgs` already packages it
(`python3Packages.mlx-vlm`), so there is nothing to build from PyPI. What's
worth keeping is one surgical source patch: a `postPatch` that stops model
loading from dragging in **torch** and **torchvision** through `transformers`'
`AutoVideoProcessor`. This recipe layers that patch onto the nixpkgs derivation
with `overridePythonAttrs`.

## The problem

Recent versions of `transformers` resolve an **`AutoVideoProcessor`** whenever a
processor is constructed for a VLM. Building that video processor imports
**torch** and **torchvision** -- eagerly, at model-load time, purely as a side
effect of `AutoProcessor.from_pretrained(...)`. For image-plus-text inference
you never process a single frame of video, but the import happens anyway. On a
model that has no torch in its closure (or a slimmed transformers built without
torchvision), that's an outright load failure; everywhere else it's pure
weight.

## The approach

You don't need the video processor to exist -- you need it to *not run*. So
monkey-patch it out at **build time**, surgically, around the one call that
triggers it, and don't rebuild the rest of the package:

```nix
python3Packages.mlx-vlm.overridePythonAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    substituteInPlace mlx_vlm/utils.py --replace-fail '<the call>' '<the wrap>'
  '';
})
```

The wrap does three things around the single `processor =
AutoProcessor.from_pretrained(...)` line in `mlx_vlm/utils.py`:

1. Replace `AutoVideoProcessor.from_pretrained` with a no-op that returns
   `None`, and relax `ProcessorMixin.check_argument_for_proper_class` so it
   accepts that `None` instead of type-checking the absent processor.
2. Run the original `AutoProcessor.from_pretrained(...)` call.
3. **Restore both originals**, so nothing else in the running process is
   affected.

With the video path neutered, the torch / torchvision import never fires; the
processor loads for image + text only.

### Why `overridePythonAttrs`, not a fresh build

An earlier version of this recipe re-vendored the whole package from the PyPI
sdist -- a hand-copied dependency list, a `version`/`hash` pin, `doCheck =
false`. That bought nothing over the nixpkgs derivation except a permanent
version lag and a manual hash bump every release. The *only* thing genuinely
reusable is the video-bypass patch, so append it to `old.postPatch` and let
nixpkgs own the version, dependencies, and checks. This is the general lesson:
when you only need to modify one thing about a packaged derivation, override
that one thing rather than re-deriving it.

### Why the patch is deliberately narrow

The replacement targets exactly one source line via `substituteInPlace ...
--replace-fail`. Two reasons:

- **Fail loud on upstream drift.** `--replace-fail` errors the build if that
  line ever changes shape in a new `mlx-vlm` release, instead of silently
  patching nothing and leaving you to discover the torch import at runtime.
- **Easy to re-audit.** A one-line surgical wrap is trivial to eyeball after a
  version bump.

### The indentation gotcha

The replaced statement lives inside an indented function body. Every injected
line *after the first* therefore carries a hard-coded four-space indent in the
Nix string -- the first line inherits the original statement's indentation (it
takes its place), the rest must supply their own. Drop that indentation and you
get a Python `IndentationError` at import time, not at build time.

## Usage

```nix
# callPackage wires python3Packages for you.
mlx-vlm = pkgs.callPackage ./default.nix { };

# or pin a specific interpreter's package set:
mlx-vlm = pkgs.callPackage ./default.nix {
  python3Packages = pkgs.python311Packages;
};
```

To run the bundled OpenAI-compatible server, wrap it:

```nix
pkgs.writeShellScriptBin "mlx-vlm-server" ''
  exec ${pkgs.python3.withPackages (_: [ mlx-vlm ])}/bin/python -m mlx_vlm.server "$@"
''
```

## Caveats

- **Video inference is gone by design.** This override is for image + text. If
  you need video, don't apply the patch -- take the torch/torchvision cost.
- **The anchor is version-coupled.** The wrapped line is specific to the
  `mlx-vlm` version your nixpkgs ships. On a bump, expect `--replace-fail` to
  catch a changed call site; re-point the anchor at the new line. (It matches
  the current nixpkgs release unchanged.)
- **Apple Silicon only.** MLX targets Metal; this builds and runs on macOS
  aarch64. The package builds without a GPU but needs Metal to actually serve.
