# python-package-gepa

Packaging an upstream Python tool for Nixpkgs when its `pyproject.toml` version
string has drifted out of sync with its git tag — and keeping the closure lean
by pushing heavy optional dependencies into extras.

The concrete package here is [GEPA](https://github.com/gepa-ai/gepa) (a prompt /
system-component optimizer), but the two techniques generalize to almost any
`buildPythonPackage` you write by hand.

## The trap: tag says v0.1.0, pyproject says 0.0.27

`buildPythonPackage` reads the wheel version out of `pyproject.toml`, **not**
from the tag you fetched. Plenty of upstreams cut a git tag (`v0.1.0`) without
bumping the `version=` line committed in the repo, so the tree at `v0.1.0` still
declares `0.0.27`.

Consequences if you don't fix it:

- The built wheel is named `0.0.27`, so `passthru`/version metadata lies.
- Any downstream package with a constraint like `gepa>=0.1.0` (or `gepa[dspy]==0.1.0`)
  fails to resolve against your build.

The fix is a one-line `postPatch`:

```nix
postPatch = ''
  substituteInPlace pyproject.toml \
    --replace-fail 'version="0.0.27"' 'version="${version}"'
'';
```

**Use `--replace-fail`, not `--replace`.** `--replace` silently does nothing if
the literal isn't found — so the day upstream finally fixes their `pyproject.toml`,
your patch becomes a no-op and you'd never notice you're now depending on stale
patch logic. `--replace-fail` turns that same event into a hard build error that
tells you to delete the workaround.

## The second lesson: heavy deps belong in `optional-dependencies`

GEPA's core is small, but its useful workflows want a big stack: `litellm` for
LLM calls, `datasets` for data handling, and experiment trackers `mlflow` /
`wandb`. Putting those in `dependencies` would force every consumer — including
ones that only import the core — to build and carry that entire closure (and
inherit its frequent breakages).

Instead they go in `optional-dependencies` keyed by use case:

```nix
optional-dependencies = {
  full = [ litellm datasets mlflow wandb tqdm ];  # everything
  dspy = [ litellm datasets tqdm ];               # DSPy integration only
};
```

Downstreams then depend on `gepa` for the lean core, or pull the extras
explicitly (e.g. a DSPy package listing `gepa` in `dependencies` and matching
the `gepa[dspy]` set). This keeps the base package importable with a minimal
closure and makes the heavy path opt-in.

## Usage

Build it directly:

```nix
python3Packages.callPackage ./default.nix { }
```

Or expose it through a `pythonPackagesExtensions` overlay so it's available as
`python3Packages.gepa`:

```nix
# overlays/python-modules/gepa.nix
_prev: self: _super: {
  gepa = self.callPackage ./gepa.nix { };
}
```

```nix
# in your overlay that assembles pythonPackagesExtensions
final: prev: {
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (import ./python-modules/gepa.nix)
  ];
}
```

## Caveats

- **`doCheck = false`.** Upstream's test suite reaches for live LLM providers,
  which doesn't work in the Nix build sandbox. `pythonImportsCheck = [ "gepa" ]`
  is the smoke test instead.
- **Refresh the hash on version bumps.** When you bump `version`, re-run
  `nix-prefetch-github gepa-ai gepa --rev vX.Y.Z` for the new `src.hash`, and
  re-check whether the `postPatch` version literal (`0.0.27`) still matches the
  new tag's `pyproject.toml` — update or remove it as needed. A stale
  `--replace-fail` literal will fail the build loudly, which is exactly the
  signal you want.
