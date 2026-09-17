_topPrev: _pyfinal: pyprev: {
  example-flaky-in-sandbox = pyprev.example-flaky-in-sandbox.overridePythonAttrs (old: {
    doCheck = false;
    doInstallCheck = false;
    disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
      "tests/test_needs_network.py"
    ];
  });
}
