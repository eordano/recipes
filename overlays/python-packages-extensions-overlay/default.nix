final: prev:
let
  modules = map (f: f prev) [
    (import ./python-modules/disable-sandbox-tests.nix)
    (import ./python-modules/add-missing-dependency.nix)
    (import ./python-modules/vendored-package.nix)
  ];
in
{
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ modules;

  example-accel-tool =
    if prev.config.cudaSupport or false then
      final.python3Packages.toPythonApplication final.python3Packages.example-accel-tool
    else
      prev.example-accel-tool or null;
}
