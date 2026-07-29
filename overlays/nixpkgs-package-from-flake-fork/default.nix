# Rebuild any nixpkgs package from your own flake-input fork.
#
# This is a reusable overlay factory. You point `src` at a flake input that
# holds your fork of a package's upstream source, and it rebuilds the nixpkgs
# derivation of that package against your tree — keeping every other build
# input, wrapper, and passthru that nixpkgs already wired up.
#
# Why an overlay factory and not a hand-written derivation: nixpkgs packages
# often carry a lot of build machinery (wrappers, patches, passthru, checks,
# platform handling). `overrideAttrs` lets you swap ONLY the source and version
# while inheriting all of that, so you track upstream's packaging for free.
#
# Usage (flake.nix):
#
#   inputs.my-app-fork.url = "github:you/app-fork/my-branch";
#
#   overlays = [
#     (import ./overlays/nixpkgs-package-from-flake-fork {
#       pname = "someapp";              # attribute name in nixpkgs
#       src   = inputs.my-app-fork;     # your fork, as a flake input
#     })
#   ];
#
# The overlay is a plain `final: prev:` function, so it composes with any other
# overlay and works anywhere nixpkgs overlays are accepted.

{
  # Attribute name of the package in nixpkgs, e.g. "someapp".
  pname,

  # The flake input holding your fork. A flake source exposes `shortRev` (and
  # `rev`), which we use to derive a version string. Passing the input directly
  # as `src` also pins the build to that exact revision.
  src,

  # Label prefixed to the derived version string. Use it to make it obvious in
  # `nix-store -q` / `--version` output that this is your fork, not upstream.
  versionPrefix ? "fork",

  # Your fork's test suite may diverge from upstream's (renamed tests, dropped
  # fixtures, different assumptions). Leaving checks ON will usually fail the
  # build for reasons that have nothing to do with your change, so this defaults
  # to false. Flip to true only if you actively maintain the fork's tests.
  doCheck ? false,

  # Set true when your fork already carries the patches nixpkgs applies on top of
  # upstream — otherwise nixpkgs' patches will fail to apply against your tree
  # (already-applied hunks) or double-apply. Clearing `patches` hands patching
  # responsibility entirely to your fork.
  clearPatches ? false,
}:

final: prev:

{
  ${pname} = prev.${pname}.overrideAttrs (old:
    {
      # `shortRev` is only present when the input is a clean git/flake ref; the
      # `or "dev"` fallback keeps `nix flake check` and dirty local trees working.
      version = "${versionPrefix}-${src.shortRev or "dev"}";
      src = src;
    }
    // (if doCheck then { } else { doCheck = false; doInstallCheck = false; })
    // (if clearPatches then { patches = [ ]; } else { })
  );
}
