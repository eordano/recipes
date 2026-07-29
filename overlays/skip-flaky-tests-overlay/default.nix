# A nixpkgs overlay: a small toolbox for surgically disabling package checks
# that fail under CPU emulation (qemu-user cross builds) or heavy parallel
# builder load — without perturbing the derivation hash more than necessary.
#
# Import it as a nixpkgs overlay, e.g.:
#
#   nixpkgs.overlays = [ (import ./skip-flaky-tests-overlay) ];
#
# or in a flake:
#
#   pkgs = import nixpkgs { inherit system; overlays = [ (import ./skip-flaky-tests-overlay) ]; };
#
# The entries below the helpers are ILLUSTRATIVE examples only. Delete them and
# add your own — the reusable value is the four helper functions and the
# ordering/import-check traps they encode, not this particular package list.
#
# WARNING: dropping doCheck (or otherwise mutating attrs) changes the output
# hash, so the package no longer matches the upstream binary cache and rebuilds
# from source everywhere. Only override packages you are already building
# locally; leave cache-hitting packages untouched.

_: prev:
let
  # Drop the standard check + installCheck phases (C / meson / cargo / generic).
  skipChecks =
    pkg:
    pkg.overrideAttrs (_: {
      doCheck = false;
      doInstallCheck = false;
    });

  # Same, for a Python package (uses overridePythonAttrs so buildPythonPackage
  # picks the change up correctly).
  skipPyChecks =
    pkg:
    pkg.overridePythonAttrs (_: {
      doCheck = false;
      doInstallCheck = false;
    });

  # The important one. Some packages have a native extension module whose
  # *import* crashes the emulator (or otherwise aborts) before pytest ever
  # runs. buildPythonPackage's pythonImportsCheckHook imports every module in
  # `pythonImportsCheck` during installCheck — so clearing doCheck alone is not
  # enough; the crash fires in the import hook, not in the test suite. This
  # helper clears the import list AND disables the hook as well.
  skipPyAllChecks =
    pkg:
    pkg.overridePythonAttrs (_: {
      doCheck = false;
      doInstallCheck = false;
      pythonImportsCheck = [ ];
      dontUsePythonImportsCheck = true;
    });

  # Keep the suite, drop only specific flaky tests by name/pattern (pytest -k
  # deselection via nixpkgs' disabledTests). Preferred over skipPyChecks when a
  # single test is the problem — you keep coverage for everything else.
  disablePyTests =
    tests: pkg:
    pkg.overridePythonAttrs (old: {
      disabledTests = (old.disabledTests or [ ]) ++ tests;
    });
in
{
  # ---- Non-Python examples -------------------------------------------------

  # A C/meson package whose suite times out or is flaky under emulation.
  age = skipChecks prev.age;
  libsecret = skipChecks prev.libsecret;

  # Some meson packages gate tests behind a build flag as well as doCheck —
  # flip the flag too, or the test binaries still get compiled (slow under
  # emulation) even though they are never run.
  power-profiles-daemon = prev.power-profiles-daemon.overrideAttrs (old: {
    doCheck = false;
    doInstallCheck = false;
    mesonFlags = builtins.map (
      f: if f == "-Dtests=true" then "-Dtests=false" else f
    ) (old.mesonFlags or [ ]);
  });

  # CMake packages often let you exclude a single failing test target rather
  # than the whole suite.
  thrift = prev.thrift.overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [
      (prev.lib.cmakeFeature "EXCLUDE_TESTS" "TServerIntegrationTest")
    ];
    disabledTests = (old.disabledTests or [ ]) ++ [ "TServerIntegrationTest" ];
    doCheck = false;
  });

  # Rename a single failing test in-source via postPatch (turns test_foo into
  # no_test_foo so the collector skips it) when the package has no clean
  # deselection knob.
  kitty = prev.kitty.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace kitty_tests/check_build.py \
        --replace-quiet test_macos_dictation_forwarding no_test_macos_dictation_forwarding
    '';
  });

  # ---- Python examples -----------------------------------------------------
  #
  # Extend every python interpreter's package set. Using
  # pythonPackagesExtensions (rather than overriding a single pythonPackages)
  # applies the fix across python3Packages, the vendored sets inside other
  # packages, etc.
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (_: pprev: {
      # Whole-suite skip: OOM-killed / aborts under load.
      aiohttp = skipPyChecks pprev.aiohttp;
      twisted = skipPyChecks pprev.twisted;

      # Single-test deselection — keeps the rest of the coverage.
      rich = disablePyTests [ "test_brokenpipeerror" ] pprev.rich;
      dulwich = disablePyTests [
        "test_no_decode_encode"
        "test_cyrillic"
      ] pprev.dulwich;

      # THE TRAP: contourpy's native import crashes the emulator itself, and
      # matplotlib imports contourpy during its own import check — both need
      # the import hook cleared, not just doCheck. This is exactly the case
      # skipPyChecks does NOT cover and skipPyAllChecks does.
      contourpy = skipPyAllChecks pprev.contourpy;
      matplotlib = skipPyAllChecks pprev.matplotlib;

      # Compose helpers with a further override when a package needs both a
      # check skip and a missing dependency wired back in.
      slicer = (skipPyChecks pprev.slicer).overridePythonAttrs (old: {
        build-system = (old.build-system or [ ]) ++ [ pprev.setuptools ];
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pprev.setuptools ];
      });

      # Runtime-deps metadata check failing because nixpkgs didn't wire a
      # wheel-declared dep: either add the dep back...
      shap = pprev.shap.overridePythonAttrs (old: {
        dependencies = (old.dependencies or [ ]) ++ [ pprev.typing-extensions ];
      });
      # ...or, when the dep genuinely isn't needed at build time, just turn
      # the runtime-deps check off.
      outlines = pprev.outlines.overridePythonAttrs (_: {
        dontCheckRuntimeDeps = true;
      });
    })
  ];
}
