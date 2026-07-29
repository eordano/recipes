# python-packages-extensions-overlay
#
# Route Python package overrides through `pythonPackagesExtensions` instead of
# a flat `python3Packages` override, so every patch stacks across *every*
# interpreter version present in the tree (python311Packages, python312Packages,
# python313Packages, …) rather than silently touching only the one you named.
#
# A flat `python3Packages.overrideScope (…)` only rewrites the scope bound to the
# current default interpreter. Anything in the tree that pulls a *different*
# interpreter — a package pinned to 3.11, a tool that ships its own python3.env,
# a cross build — gets the unpatched package back, and the failure is silent:
# the build succeeds, it just uses the version you thought you had fixed.
# `pythonPackagesExtensions` is the list nixpkgs threads into the construction of
# *all* interpreter package sets, so appending to it applies your override once
# and everywhere.
#
# This is a standard nixpkgs overlay: `final: prev:`. Add it to
# `nixpkgs.overlays` (NixOS) or `import nixpkgs { overlays = [ ... ]; }`.

final: prev:
let
  # Each member is a function that receives the top-level `prev` (so a module can
  # reach `prev.lib`, `prev.fetchFromGitHub`, `prev.config`, etc.) and returns a
  # python-package-set extension of the usual `pyfinal: pyprev: { … }` shape.
  #
  # The doubly-nested signature that shows up in the module files below is:
  #
  #     topPrev: pyfinal: pyprev: { <pkg> = ...; }
  #      \_____/  \_____/  \_____/
  #       │        │        └─ the previous python package set (a.k.a. `super`)
  #       │        └────────── the final python package set    (a.k.a. `self`)
  #       └─────────────────── the top-level `prev` pkgs set
  #
  # Use `pyprev.<pkg>.overridePythonAttrs` to patch an existing package, or
  # `pyfinal.callPackage` to add a new one. Prefer `pyfinal` when you want a
  # value that itself may have been patched by a later extension in the list.
  modules = map (f: f prev) [
    (import ./python-modules/disable-sandbox-tests.nix)
    (import ./python-modules/add-missing-dependency.nix)
    (import ./python-modules/vendored-package.nix)
  ];
in
{
  # Append (never replace) so extensions contributed by other overlays survive.
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ modules;

  # Conditionally re-wrap a *library* as a top-level *application*.
  #
  # Some packages are only usable as a CLI on machines that have the right
  # accelerator/build support (here: CUDA). `toPythonApplication` takes the
  # library derivation from the (already-patched) python package set and exposes
  # it as a top-level runnable program — but only where it makes sense to build.
  # Elsewhere we pass the upstream attribute through unchanged, falling back to
  # `null` if nixpkgs doesn't define it at all, so evaluation never throws.
  #
  # Swap `example-accel-tool` / `cudaSupport` for your own package and gate.
  example-accel-tool =
    if prev.config.cudaSupport or false then
      final.python3Packages.toPythonApplication final.python3Packages.example-accel-tool
    else
      prev.example-accel-tool or null;
}
