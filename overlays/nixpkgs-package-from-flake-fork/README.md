# nixpkgs-package-from-flake-fork

Rebuild any nixpkgs package from **your own fork** of its source — carried as a
flake input — with a one-line `overrideAttrs` overlay. You keep everything
nixpkgs already did to package it (wrappers, build inputs, passthru, platform
handling) and swap only the source tree and version.

## The problem

You maintain a fork of some upstream project (a rebrand, a backported fix, a
feature branch) and you want your NixOS/home-manager config to build *that*,
not the pinned upstream release nixpkgs ships. Writing a fresh derivation means
re-deriving all the packaging that nixpkgs already got right. You don't want to
own that — you only want to redirect the source.

## The insight

`prev.<pkg>.overrideAttrs` lets you replace just `src` (and `version`) while
inheriting the rest of nixpkgs' derivation. Point `src` straight at the flake
input holding your fork and three details fall out:

- **Version from the revision.** A flake input exposes `shortRev`, so
  `version = "${prefix}-${src.shortRev or "dev"}"` gives every build a
  meaningful, fork-labelled version with zero manual bumping. The `or "dev"`
  fallback matters: `shortRev` is absent for dirty local trees and some
  `nix flake check` paths, and without the fallback those evaluations throw.

- **Tests off by default (`doCheck = false`).** This is the main trap. A fork's
  test suite almost always diverges from upstream's — renamed cases, dropped
  fixtures, different assumptions — so nixpkgs' check phase fails for reasons
  unrelated to your change. Unless you actively maintain the fork's tests,
  leave checks off.

- **Clear patches when the fork already carries them (`clearPatches = true`).**
  If your fork already includes the patches nixpkgs applies on top of upstream,
  nixpkgs will try to apply them again against a tree that already has them —
  and fail on already-applied hunks. Set `clearPatches = true` to hand all
  patching to your fork.

## Usage

```nix
# flake.nix
{
  inputs.my-app-fork.url = "github:you/app-fork/my-branch";

  # ... in your nixpkgs config / colmena / nixosConfigurations:
  nixpkgs.overlays = [
    (import ./overlays/nixpkgs-package-from-flake-fork {
      pname = "someapp";           # attribute name in nixpkgs
      src   = inputs.my-app-fork;  # your fork, passed as a flake input
    })
  ];
}
```

That's it — `pkgs.someapp` now builds from your fork, versioned
`fork-<shortRev>`.

## Options

| Option          | Default    | Purpose |
|-----------------|------------|---------|
| `pname`         | *required* | Attribute name of the package in nixpkgs. |
| `src`           | *required* | The flake input holding your fork (used as `src` and to derive the version). |
| `versionPrefix` | `"fork"`   | Prefix on the derived version string, so `--version` output makes the fork obvious. |
| `doCheck`       | `false`    | Run the check/installCheck phases. Turn on only if you maintain the fork's tests. |
| `clearPatches`  | `false`    | Drop nixpkgs' `patches`. Set when your fork already carries them. |

## Caveats

- **Passthru overrides.** `overrideAttrs` runs on `prev.<pkg>`, so it does not
  see *later* overlays. If a downstream override must still apply (e.g. another
  overlay swaps a dependency), apply this overlay first or use
  `final.callPackage` machinery instead.

- **`src` must match the derivation's build assumptions.** You're only swapping
  the source; the build phases, dependencies, and directory layout still come
  from nixpkgs. If your fork restructures the tree or changes the build system,
  a source swap alone won't be enough — you'll need a fuller override.

- **Version string is cosmetic.** `version` here is just a label; it does not
  gate anything. Some packages embed their own version at build time from the
  source, which will show independently.
