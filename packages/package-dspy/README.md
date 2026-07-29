# package-dspy

Package the [DSPy](https://github.com/stanfordnlp/dspy) Python LLM framework
(programming — not prompting — language models) for Nix, working around three
things upstream does that break a naive `buildPythonPackage`.

## The problem

DSPy is not on nixpkgs at the version you probably want, and building it from
the GitHub tag hits three obstacles that each fail the build in a different,
confusing way:

1. **The version string in the tagged tree doesn't match the tag.** The git
   tag is `3.1.3` but the checked-in `dspy/__metadata__.py` and
   `pyproject.toml` still say `3.1.2`. `buildPythonPackage` reads its dist
   metadata from `pyproject.toml`, so the wheel comes out labelled `3.1.2`.
   Nothing errors — you just get a package that lies about its own version, and
   any downstream `dspy>=3.1.3` constraint or `dspy.__version__` assertion
   fails later, far from the cause.

2. **Some dependencies are pinned with `==`.** `asyncer==0.0.8` and
   `gepa[dspy]==0.0.26` are exact pins. nixpkgs almost never has the exact
   point release upstream pinned, so the runtime dependency check rejects the
   perfectly-compatible version nixpkgs does have.

3. **Most of the test suite needs a live LLM and the network.** Whole test
   directories drive real OpenAI/Anthropic calls, open outbound sockets, or
   fetch remote PDF/mime fixtures. A hermetic build sandbox has no network, so
   these can never pass and must be excluded — otherwise the build fails on
   tests that were never going to run.

## The fix (and the key insight)

All of these live in `default.nix` — the three upstream workarounds, plus one
Nix-side trap the sandbox forces on you:

- **Rewrite the version strings in `postPatch`** with `substituteInPlace ...
  --replace-fail`. The important detail is `--replace-fail`, **not**
  `--replace`: it makes the build **fail loudly** the day upstream fixes their
  strings, so the patch can never silently become a no-op that leaves you back
  at the mislabelled-wheel bug. Patch both `dspy/__metadata__.py` *and*
  `pyproject.toml` — they carry the version independently.

- **Loosen the `==` pins to `>=`** in `pyproject.toml`, again via
  `substituteInPlace --replace-fail`. Only loosen the ones that actually drift
  against nixpkgs (`asyncer`, `gepa`); leave the rest alone.

- **Disable the network/LLM tests in two tiers.** Directories that are
  end-to-end LLM tests go in `disabledTestPaths` (dropped wholesale);
  individual network cases that live inside otherwise-useful test files go in
  `disabledTests` (dropped by test name). `pythonImportsCheck = [ "dspy" ]`
  still gives you a real smoke test that the package imports.

- **Redirect `DSPY_CACHEDIR` with an exported shell variable, not `env`.** DSPy
  chooses its on-disk cache directory at *import* time and falls back to
  `$HOME/.dspy_cache`, which is not writable in the sandbox — so both the test
  run and `pythonImportsCheck` need it moved. The trap is *how*: attribute
  values under `env` are passed to the builder **verbatim**. Nothing expands
  them — not the shell, and certainly not make, so a value like
  `"$(TMPDIR)/dummy"` is not "the sandbox tempdir", it is the literal 15-byte
  string `$(TMPDIR)/dummy`, and DSPy happily creates a directory *named*
  `$(TMPDIR)` next to the build cwd. Because `$TMPDIR` only exists inside the
  builder, the redirect has to be an `export` from a hook — `preBuild` here,
  since all phases share one shell and `preBuild` precedes the check,
  installCheck and preDist phases where pytest and the imports check run.

## Usage

Call it as a Python package, typically from an overlay:

```nix
final: prev: {
  python3 = prev.python3.override {
    packageOverrides = pfinal: pprev: {
      dspy = pfinal.callPackage ./default.nix { };
    };
  };
}
```

Then `python3.pkgs.dspy` (and `python3.withPackages (ps: [ ps.dspy ])`) are
available. Optional feature sets are exposed under `optional-dependencies`
(`anthropic`, `langchain`, `mcp`, `weaviate`, …).

## Caveats / bumping the version

- **When you change `version`,** update the `src` `hash` (a failing build will
  print the correct `sha256-…`), and re-check the two `--replace-fail` version
  strings — if upstream has since made their metadata consistent, those
  replacements will now fail (by design) and you simply remove them.
- The `==`→`>=` loosening list and the disabled-test list are both tied to a
  specific upstream release. On a bump, expect to add/remove a few names as
  upstream reshuffles pins and tests.
- This packages a moving target from a GitHub tag, not a stable nixpkgs
  derivation — treat the pinned lists as maintenance surface, not fire-and-forget.
