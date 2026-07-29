# Worked example of a *vendored* Python package: a derivation you maintain
# yourself because the pinned nixpkgs either does not ship the package at all
# or ships a version that is too old.
#
# It is `callPackage`d from `../python-modules/vendored-package.nix` on
# `pyfinal` (the *final* python package set), so every input resolved here —
# `buildPythonPackage`, `setuptools`, `requests` — comes from the same patched
# set, for whichever interpreter the extension is currently running against.
#
# Everything below is a placeholder shaped like the real thing. Replace pname /
# version / src / hash / inputs with yours. `hash` is deliberately
# `lib.fakeHash`: evaluation succeeds (so an overlay that merely *mentions*
# this package still evaluates), and the first build prints the real hash to
# paste back in.
{
  lib,
  buildPythonPackage,
  fetchPypi,
  setuptools,
  requests,
}:

buildPythonPackage rec {
  pname = "example-vendored";
  version = "1.2.3";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = lib.fakeHash;
  };

  build-system = [ setuptools ];

  dependencies = [ requests ];

  # Cheap smoke test that the module actually imports with the closure above.
  pythonImportsCheck = [ "example_vendored" ];

  meta = {
    description = "Placeholder vendored Python package (replace with your own)";
    homepage = "https://example.invalid/example-vendored";
    license = lib.licenses.mit;
  };
}
