_: prev:
let
  skipChecks =
    pkg:
    pkg.overrideAttrs (_: {
      doCheck = false;
      doInstallCheck = false;
    });

  skipPyChecks =
    pkg:
    pkg.overridePythonAttrs (_: {
      doCheck = false;
      doInstallCheck = false;
    });

  skipPyAllChecks =
    pkg:
    pkg.overridePythonAttrs (_: {
      doCheck = false;
      doInstallCheck = false;
      pythonImportsCheck = [ ];
      dontUsePythonImportsCheck = true;
    });

  disablePyTests =
    tests: pkg:
    pkg.overridePythonAttrs (old: {
      disabledTests = (old.disabledTests or [ ]) ++ tests;
    });
in
{

  age = skipChecks prev.age;
  libsecret = skipChecks prev.libsecret;

  power-profiles-daemon = prev.power-profiles-daemon.overrideAttrs (old: {
    doCheck = false;
    doInstallCheck = false;
    mesonFlags = builtins.map (f: if f == "-Dtests=true" then "-Dtests=false" else f) (
      old.mesonFlags or [ ]
    );
  });

  thrift = prev.thrift.overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [
      (prev.lib.cmakeFeature "EXCLUDE_TESTS" "TServerIntegrationTest")
    ];
    disabledTests = (old.disabledTests or [ ]) ++ [ "TServerIntegrationTest" ];
    doCheck = false;
  });

  kitty = prev.kitty.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace kitty_tests/check_build.py \
        --replace-quiet test_macos_dictation_forwarding no_test_macos_dictation_forwarding
    '';
  });

  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (_: pprev: {
      aiohttp = skipPyChecks pprev.aiohttp;
      twisted = skipPyChecks pprev.twisted;

      rich = disablePyTests [ "test_brokenpipeerror" ] pprev.rich;
      dulwich = disablePyTests [
        "test_no_decode_encode"
        "test_cyrillic"
      ] pprev.dulwich;

      contourpy = skipPyAllChecks pprev.contourpy;
      matplotlib = skipPyAllChecks pprev.matplotlib;

      slicer = (skipPyChecks pprev.slicer).overridePythonAttrs (old: {
        build-system = (old.build-system or [ ]) ++ [ pprev.setuptools ];
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pprev.setuptools ];
      });

      shap = pprev.shap.overridePythonAttrs (old: {
        dependencies = (old.dependencies or [ ]) ++ [ pprev.typing-extensions ];
      });
      outlines = pprev.outlines.overridePythonAttrs (_: {
        dontCheckRuntimeDeps = true;
      });
    })
  ];
}
