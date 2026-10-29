# transformers-v5-overlay

Run a fast-moving Python package ahead of your nixpkgs pin when a major
version bump also reshuffles that package's dependencies. The worked example is
HuggingFace `transformers` v5, but the pattern applies to any Python library
whose major release moves its transitive dependency surface faster than nixpkgs
tracks it.

## The problem

You want a newer `transformers` than the one your pinned nixpkgs ships. The
obvious move is a source pin:

```nix
transformers = prev.transformers.overridePythonAttrs (_: {
  version = "5.18.0";
  src = fetchFromGitHub { ... };
});
```

That builds the new source against the old dependency closure. A minor
bump usually survives this. A major bump often does not: the new release adds,
drops, or swaps runtime deps (transformers v5 started depending on `typer`;
`huggingface-hub` went to 1.x and grew new deps of its own). `overridePythonAttrs`
does not re-derive `dependencies` from the new `pyproject.toml` -- it keeps
whatever the pinned derivation already had. So you get one of:

- a build that fails because a now-required dep isn't in the inputs, or
- a build that succeeds but imports stale transitive versions at runtime.

## The insight / the trap

A major bump is not one pin -- it is a small pinned subgraph, and every node
in it needs its `dependencies` list written out by hand:

1. Bump `transformers` (source + version + rewritten `dependencies`).
2. Bump `huggingface-hub` to the version the new transformers targets -- again
   with a hand-written `dependencies`, because its deps shifted too (1.33 needs
   `click>=8.4.2` only to dodge a broken fish completion in 8.4.0/8.4.1, so
   `pythonRelaxDeps = [ "click" ]` keeps nixpkgs' click). Stay on hub 1.x:
   transformers 5.18 accepts `<3.0`, but every `datasets` release up to 5.0.1
   pins `huggingface-hub<2.0`, and this overlay replaces hub for the whole
   package set, `datasets` and everything that pulls it in included.
3. Bump `typer` (a new transitive dep) and its `dependencies` -- 0.27 vendors
   click as `typer._click`, so the list is `shellingham`, `rich` and
   `annotated-doc`.
4. Alias `typer-slim = typer`. Older consumers still reference `typer-slim`,
   which nixpkgs has dropped, so the alias keeps the closure resolving without
   a second full build.
5. Disable `doCheck` on the leaf consumers (`accelerate`,
   `sentence-transformers`) whose pinned test suites lag the bumped deps. This
   is build-time only; runtime behaviour is unaffected.

The load-bearing detail is step-by-step `dependencies = [ ... ]`. That list
is the thing `overridePythonAttrs` won't compute for you, and getting it right
means reading each release's `pyproject.toml`.

Everything is packaged through `pythonPackagesExtensions`, not a flat
`python3Packages` override, so the overrides stack across every Python
interpreter in the tree. A flat override only patches one interpreter and
silently misses the rest.

## Usage

```nix
nixpkgs.overlays = [ (import ./overlays/transformers-v5-overlay) ];
```

Anything that consumes `python3Packages.transformers` (and the bumped deps) then
uses these builds. No other wiring is required.

## Bumping the pins

For each of `typer`, `huggingface-hub`, `transformers`:

1. Set the new `version` / `tag`.
2. Set `hash` to `prev.lib.fakeHash`, build, and copy the real hash from the
   error (or use `nix-prefetch-github <owner> <repo> --rev <tag>`).
3. Re-diff the `dependencies` list against that release's `pyproject.toml`.
   This is the manual step the whole recipe exists for -- a stale list is the
   failure mode.

## Caveats

- This is a stopgap. Once your nixpkgs pin ships the versions you need,
  delete the overlay and go back to the packaged builds -- carrying a source pin
  means you also carry the burden of tracking upstream security fixes yourself.
- The hashes and versions here are a concrete example. Treat them as a template,
  not a target; they will be stale by the time you read this.
- `doCheck = false` skips upstream test suites. That is intentional for a
  version-ahead pin (the pinned tests assume the pinned deps), but it means you
  are trusting the build without running its checks -- validate the packages you
  care about at runtime.
