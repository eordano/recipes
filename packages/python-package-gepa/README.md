# python-package-gepa

A technique demo: realigning a hand-written `buildPythonPackage` version
string with the git tag you actually fetched (via `substituteInPlace ...
--replace-fail`), and keeping the closure lean by pushing heavy optional
dependencies into extras.

> You do not need this to get GEPA. nixpkgs now ships
> `python3Packages.gepa` (0.1.3 at time of writing, built from tag `v0.1.3`) --
> just use that. This recipe tracks the latest tag (`v0.1.4`), whose committed
> `pyproject.toml` still declares `version="0.1.3"`; that drift is a clean, real
> example of the problem the technique solves. Treat the file as a template
> for the next package you hand-write, not as the way to obtain GEPA.

[GEPA](https://github.com/gepa-ai/gepa) is a prompt / system-component
optimizer, but the two techniques below generalize to almost any
`buildPythonPackage` you write by hand.

## The trap: tag says v0.1.4, pyproject says 0.1.3

`buildPythonPackage` reads the wheel version out of `pyproject.toml`, not
from the tag you fetched. Plenty of upstreams cut a git tag (`v0.1.4`) without
bumping the `version=` line committed in the repo, so the tree at `v0.1.4` still
declares `0.1.3`.

Consequences if you don't fix it:

- The built wheel is named `0.1.3`, so `passthru`/version metadata lies.
- Any downstream package with a constraint like `gepa>=0.1.4` (or `gepa[dspy]==0.1.4`,
  which is exactly what dspy 3.4.0 declares)
  fails to resolve against your build.

The fix is a one-line `postPatch`:

```nix
postPatch = ''
  substituteInPlace pyproject.toml \
    --replace-fail 'version="0.1.3"' 'version="${version}"'
'';
```

Use `--replace-fail`, not `--replace`. `--replace` silently does nothing if
the literal isn't found -- so the day upstream finally fixes their `pyproject.toml`,
your patch becomes a no-op and you'd never notice you're now depending on stale
patch logic. `--replace-fail` turns that same event into a hard build error that
tells you to delete the workaround.

## The second lesson: heavy deps belong in `optional-dependencies`

GEPA's core is small, but its useful workflows want a big stack: `litellm` for
LLM calls, `datasets` for data handling, and experiment trackers `mlflow` /
`wandb`. Putting those in `dependencies` would force every consumer -- including
ones that only import the core -- to build and carry that entire closure (and
inherit its frequent breakages).

Instead they go in `optional-dependencies` keyed by use case:

```nix
optional-dependencies = {
  full = [ litellm tqdm cloudpickle datasets mlflow wandb ];  # everything
  dspy = [ ];  # DSPy brings its own litellm; the extra is empty upstream
};
```

Downstreams then depend on `gepa` for the lean core, or pull the extras
explicitly (e.g. a DSPy package listing `gepa` in `dependencies` and matching
the `gepa[dspy]` set). This keeps the base package importable with a minimal
closure and makes the heavy path opt-in.

## Usage

Build the demo directly to see the technique run:

```nix
python3Packages.callPackage ./default.nix { }
```

For a package that genuinely isn't in nixpkgs, adapt the file and expose it
through a `pythonPackagesExtensions` overlay so it lands as
`python3Packages.<yourpkg>`:

```nix
# overlays/python-modules/yourpkg.nix
_prev: self: _super: {
  yourpkg = self.callPackage ./yourpkg.nix { };
}
```

```nix
# in your overlay that assembles pythonPackagesExtensions
final: prev: {
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (import ./python-modules/yourpkg.nix)
  ];
}
```

(You would not do this for `gepa` itself -- nixpkgs already carries it as
`python3Packages.gepa`. If you need a newer GEPA than nixpkgs has, bump that
derivation via an override rather than re-vendoring this demo.)

## Caveats

- `doCheck = false`. Upstream's test suite reaches for live LLM providers,
  which doesn't work in the Nix build sandbox. `pythonImportsCheck = [ "gepa" ]`
  is the smoke test instead.
- On a bump, re-run `nix-prefetch-github <owner> <repo> --rev vX.Y.Z` for the
  new `src.hash` and re-check the version literal against the new tag's
  `pyproject.toml`. The day upstream makes it match the tag, the
  `--replace-fail` fails the build: delete the `postPatch` then.
