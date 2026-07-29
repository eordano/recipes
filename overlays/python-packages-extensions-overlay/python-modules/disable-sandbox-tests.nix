# Disable tests that fail only under the Nix build sandbox — no network,
# no /dev/ptmx, tight fd limits — not because of a real regression.
#
# Note: disabling `doCheck` is no longer always enough. Several nixpkgs python
# packages moved their pytest run into `nativeInstallCheckInputs`, so the tests
# run in the *installCheck* phase and `doCheck = false` alone won't silence them.
# Disable both phases to be safe.
_topPrev: _pyfinal: pyprev: {
  example-flaky-in-sandbox = pyprev.example-flaky-in-sandbox.overridePythonAttrs (old: {
    doCheck = false;
    doInstallCheck = false;
    # Or, to drop only specific paths instead of the whole suite:
    disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
      "tests/test_needs_network.py"
    ];
  });
}
