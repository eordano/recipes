# Add a package that isn't in the pinned nixpkgs at all (or is too old), by
# building a vendored derivation. `callPackage` on `pyfinal` (self) gives it the
# patched python package set for its own inputs.
#
# The referenced derivation ships with this recipe, so the attribute evaluates
# and resolves to a real (if placeholder-sourced) package rather than throwing
# on a missing path. Point it at your own package file.
_topPrev: pyfinal: _pyprev: {
  example-vendored = pyfinal.callPackage ../packages/example-vendored.nix { };
}
