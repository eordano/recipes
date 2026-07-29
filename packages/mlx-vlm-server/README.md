# mlx-vlm-server

Package [Apple MLX](https://github.com/ml-explore/mlx)'s vision-language
inference server as a standalone Nix binary, with two build-time source patches
that any Apple-Silicon user running local VLMs runs into sooner or later.

Apple-Silicon only — `mlx` is Metal-backed, so build and run on nix-darwin /
`aarch64-darwin`.

## What it solves

`mlx-vlm` ships `python -m mlx_vlm.server`, an OpenAI-compatible endpoint for
vision-language models. Two things get in the way of using it as-is:

1. **Text-only / image-only VLMs drag in torchvision.** Loading a model calls
   `transformers`' `AutoProcessor`, which eagerly builds an `AutoVideoProcessor`
   — and that pulls in a full PyTorch + torchvision closure. Plenty of capable
   VLMs never touch video, so this is pure closure bloat (and, on some models,
   an outright load failure).

2. **Reasoning models emit raw `<think>…</think>`.** Qwen3-style models stream
   their chain-of-thought inline in `content`. Clients that expect an OpenAI
   `reasoning_content` field (or that simply should not show the scratchpad to
   users) get the reasoning dumped straight into the answer. Worse, many
   community MLX quantizations **strip the `chat_template`** from
   `tokenizer_config.json`, so the model never gets its `<think>` prompt at all.

## The key insight / trap

Both fixes are **build-time source patches** on the packaged Python, not runtime
config — the upstream server has no hook for either.

- **Video bypass** (`postPatch`, `substituteInPlace mlx_vlm/utils.py`): wrap the
  single `AutoProcessor.from_pretrained` call so that, *for the duration of that
  call only*, `AutoVideoProcessor.from_pretrained` returns `None` and the class
  check that would reject a `None` video processor is relaxed. Both originals
  are restored immediately after. The processor loads torchvision-free; video is
  simply absent. The trap is that this is a targeted, self-reverting monkeypatch
  around one call — patch too broadly and you break real video models; patch too
  narrowly (or forget to restore) and you corrupt later processor loads.

- **Reasoning split + chat-template recovery** (`thinking-patch.py`): a
  streaming state machine (`ThinkingTagParser`) that separates `<think>…</think>`
  into `reasoning_content` on both the streaming and non-streaming code paths,
  plus an `_ensure_chat_template` helper that re-hydrates a missing
  `chat_template` — first from a sibling `tokenizer_config.json` (offline), then
  from the base (non-quantized) model repo on Hugging Face. The parser buffers
  while undecided (reasoning is hidden anyway, so the latency is invisible) and
  handles both "model opens `<think>`" and "chat template already opened
  `<think>`, model only emits the closing tag" cases.

Because these are `postPatch` steps, the patched behavior is baked into the Nix
store path and reproduces exactly — no per-run flags, no drift.

- **Only patch what you actually patch.** `mlx-vlm`'s text-only dependency,
  `mlx-lm`, needs no patching, so this recipe does not build it — it takes
  `python3Packages.mlx-lm` from nixpkgs. An earlier version re-vendored it from
  the PyPI sdist with a hand-copied dependency list and `doCheck = false`, which
  bought nothing and cost a permanent version lag plus a manual hash bump per
  release. If you need a different `mlx-lm`, override the nixpkgs derivation and
  pass it in; keep the vendoring for the package whose source you genuinely
  modify.

- **`sentencepiece` is not a runtime dep in nixpkgs.** Upstream `mlx-lm`
  declares `transformers[sentencepiece]`, but nixpkgs carries `sentencepiece` as
  a check input only. Models whose tokenizer is a SentencePiece
  `tokenizer.model` with no fast `tokenizer.json` fail to load without it, so the
  server env adds it back via `extraPythonPackages`.

## Usage

Import the file and build one of the three attributes it exposes:

```nix
let
  mlx = import ./packages/mlx-vlm-server { inherit pkgs; };
in
  mlx.mlx-vlm-server   # the server binary
```

Or straight from the CLI:

```sh
nix-build -A mlx-vlm-server   # OpenAI-compatible server binary
nix-build -A mlx-vlm          # the patched Python package
nix-build -A mlx-lm           # the text-only dependency (nixpkgs', re-exported)
```

Need a different `mlx-lm` than your nixpkgs ships? Override rather than
re-vendor:

```nix
import ./packages/mlx-vlm-server {
  inherit pkgs;
  mlx-lm = pkgs.python3Packages.mlx-lm.overridePythonAttrs (old: rec {
    version = "0.31.4";
    src = old.src.override {
      tag = "v${version}";
      hash = "sha256-...";
    };
  });
}
```

Run it — all args pass through to `python -m mlx_vlm.server`:

```sh
mlx-vlm-server --model <hf-repo-or-local-path> --host 127.0.0.1 --port 8080
```

Then hit it as an OpenAI chat endpoint. Reasoning models return their
chain-of-thought in `reasoning_content`, with the user-facing answer in
`content`.

### Serving it as a daemon

The binary is intentionally plain (a `writeShellScriptBin` wrapper, no baked-in
host/port), so wiring it into a service is trivial. Point your model cache at the
build via the standard Hugging Face env vars and launch one instance per model:

```
HF_HUB_CACHE=/path/to/models
TRANSFORMERS_CACHE=/path/to/models
MLX_METAL_JIT=1
```

## Caveats

- **Version bumps are hash-paired.** `mlx-vlm` pins `version` + `hash` together
  (`fetchPypi`). Bump both; grab the new hash from the failing build's `got:`
  line or `nix-prefetch-url --unpack`. `mlx-lm` needs none of this — it moves
  when your nixpkgs moves.
- **`substituteInPlace … --replace-fail` is a canary.** If a future `mlx-vlm`
  release rewrites the `AutoProcessor.from_pretrained(...)` call site, the build
  fails loudly instead of silently no-op'ing the patch. Same for the string
  anchors in `thinking-patch.py`, which `assert` on every match — treat a build
  failure there as "upstream moved the code," and re-anchor the patch.
- **opencv:** nixpkgs provides `opencv4`, not the PyPI `opencv-python` wheel, so
  the wheel dependency is dropped via `pythonRemoveDeps`.
- **Metal at runtime.** These build without a GPU but need Apple Silicon /
  Metal to actually serve; `doCheck = false` because upstream tests want network
  and Metal.
