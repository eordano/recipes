# go-vendor-patch-prefix-rewrite

Apply an upstream patch to a **Nix-vendored Go dependency** whose vendor-tree
layout doesn't match the patch's path prefixes.

## The problem

You want to carry a small upstream fix for a Go library that your package pulls
in as a vendored dependency. You grab the patch from the library's repo. It
applies cleanly *there* but fails inside your Nix build with something like
`can't find file to patch`.

Two things bite you, and they compound:

1. **Prefix mismatch.** The patch is authored against the *dependency's own*
   repo layout — its diff headers read `a/net/foo.go`, `b/net/foo.go`. But once
   vendored, that same file lives under a *module-qualified* path:
   `vendor/example.com/dep/net/foo.go`. The `a/`/`b/` prefixes never carry the
   module segment, so `patch -p1` looks for `net/foo.go` and finds nothing.

2. **Read-only vendor tree.** The `vendor/` directory produced by Nix's Go
   fetcher (`fetchVendorDir` / `vendorHash`) is read-only. Even a correctly
   targeted patch fails to write into it.

## The fix

In order:

1. `chmod -R +w` the exact vendor subtree you're about to patch.
2. `sed`-rewrite the `a/`/`b/` prefixes so they include the module qualifier.
3. Pipe the rewritten patch into `patch -d vendor -p1`.

The `-d vendor -p1` combination is what makes it resolve: `-p1` strips the
leading `a/` / `b/`, leaving `<module>/<subpath>/...`, and `-d vendor` roots
that at the vendor directory — landing exactly on
`vendor/<module>/<subpath>/...`.

## Usage

Import `default.nix` as an overlay (or copy the `patchVendoredGoDep` helper into
your own). The helper emits the chmod + sed + patch shell snippet; drop it into
an `overrideAttrs` `buildPhase` (or `postPatch`):

```nix
buildPhase = ''
  if [ -f patches/my-upstream-fix.patch ]; then
    ${patchVendoredGoDep {
      patch = "patches/my-upstream-fix.patch";
      module = "example.com/somedep"; # vendored module import path
      subpath = "internal/thing/";    # path inside the dep the patch touches
    }}
  fi

  go build -mod=vendor -o out ./cmd/tool
'';
```

### Options

| arg         | meaning                                                                 |
| ----------- | ----------------------------------------------------------------------- |
| `patch`     | path to the upstream patch, as authored against the dependency repo.    |
| `module`    | Go module import path the dep is vendored under (`example.com/foo`).     |
| `subpath`   | path *inside* the dep repo that the patch touches (`internal/thing/`). Keep the trailing slash. |
| `vendorDir` | vendor root relative to the source. Defaults to `vendor`.               |

The overlay also re-exports the helper itself as `pkgs.patchVendoredGoDep`, so a
downstream overlay can `inherit (prev) patchVendoredGoDep;` instead of copying
it. (The `example-go-package` attribute in `default.nix` is a worked example,
not something you are meant to build — replace it with your own package.)

## Caveats

- **Keep the `if [ -f ... ]` guard.** After an upstream bump the fix may land
  in the pinned version and the patch becomes redundant. Guarding on the file's
  existence means dropping the patch doesn't break the build.
- **Scope the chmod narrowly.** `chmod -R +w vendor/<module>/<subpath>` touches
  only what you patch. Don't `chmod -R +w vendor` wholesale.
- **Bumping the dep resets the vendor hash.** Any change to the dependency set
  invalidates `vendorHash`; the patch step is independent of that but runs after
  the vendor tree exists.
- **Multi-file patches:** if one patch touches several `subpath`s, either widen
  the `sed` to cover each prefix or split it — `-p1` only strips one leading
  segment, so every `a/`/`b/` in the diff must gain the same `module/` qualifier.
