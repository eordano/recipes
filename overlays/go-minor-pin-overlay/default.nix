# go-minor-pin-overlay
#
# Pin a single Go package back one Go minor when it fails to build on the
# Go toolchain your nixpkgs currently ships.
#
# The trap: nixpkgs bumps the default Go (say 1.25 -> 1.26) for the whole
# tree at once. Most Go packages follow along fine, but some (cgo-heavy or
# using unstable/internal Go APIs — gvisor's `runsc`, occasionally caddy,
# etc.) don't compile cleanly on the new minor for a while. You don't have
# to wait for an upstream fix or roll the entire nixpkgs pin back: nixpkgs
# keeps several Go minors packaged in parallel as `buildGoNNNModule`
# (buildGo123Module, buildGo124Module, buildGo125Module, ...). A Go package
# built with `buildGoModule` takes that builder as an overridable argument,
# so you can swap in an older, known-good minor for that one package and
# leave everything else on the new default.
#
# The whole fix is a `.override { buildGoModule = prev.buildGoNNNModule; }`.
# Because it's an .override (not overrideAttrs), the package is re-invoked
# from scratch with the pinned builder — passthru, tests, and the rest of
# the derivation stay intact.
#
# This file is a plain nixpkgs overlay (`final: prev: { ... }`). Add it to
# your `nixpkgs.overlays` (NixOS) or `import nixpkgs { overlays = [ ... ]; }`.
#
# --- Parameters you edit -----------------------------------------------------
#
#   package        the attribute name of the Go package to pin, e.g. "gvisor"
#   goMinorBuilder the buildGoNNNModule to pin it to, e.g. "buildGo125Module"
#
# Pick `goMinorBuilder` = the last minor on which the package built. Check
# what your nixpkgs exposes with:  nix eval nixpkgs#buildGo125Module --apply builtins.typeOf
# (or grep pkgs/development/compilers/go for the buildGoNNNModule aliases).

let
  # Edit these two lines for your package.
  package = "gvisor";
  goMinorBuilder = "buildGo125Module";
in
final: prev: {
  ${package} = prev.${package}.override {
    buildGoModule = prev.${goMinorBuilder};
  };
}

# --- Notes / variations ------------------------------------------------------
#
# * Multiple packages: repeat the attr, or fold a list:
#
#     let pins = { gvisor = "buildGo125Module"; foo = "buildGo124Module"; };
#     in final: prev:
#       builtins.mapAttrs
#         (name: builder: prev.${name}.override { buildGoModule = prev.${builder}; })
#         pins
#
# * Exact patch version (not just a minor): if you need a specific Go point
#   release rather than whatever `buildGoNNNModule` currently pins, build a
#   custom builder first and pass that instead — see README "Caveats".
#
# * Some packages call the builder under a different argument name
#   (e.g. `buildGo123Module` directly in their `callPackage` signature). If
#   `.override { buildGoModule = ...; }` has no effect, inspect the package's
#   `override.__functionArgs` to find the real argument name.
