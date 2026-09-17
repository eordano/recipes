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

  pythonImportsCheck = [ "example_vendored" ];

  meta = {
    description = "Placeholder vendored Python package (replace with your own)";
    homepage = "https://example.invalid/example-vendored";
    license = lib.licenses.mit;
  };
}
