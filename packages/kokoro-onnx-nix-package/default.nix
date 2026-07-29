# kokoro-onnx — an ONNX-based TTS inference engine, packaged for Nix.
#
# kokoro-onnx is not in nixpkgs, and neither are three of its dependencies:
#   - phonemizer-fork   (a maintained fork of `phonemizer`)
#   - espeakng-loader   (locates/loads the espeak-ng shared library)
#   - dlinfo            (tiny ctypes helper phonemizer-fork pulls in)
#
# So we hand-roll all four with buildPythonPackage straight from PyPI.
#
# THE TRAP (see README): espeakng-loader ships a *precompiled* libespeak-ng
# bundled inside its wheel, one wheel per platform. Its PyPI sdist does NOT
# build the native library, so a plain fetchPypi sdist is useless — you must
# fetch the platform-matching wheel (format = "wheel"). Pick the URL/hash for
# YOUR platform from https://pypi.org/project/espeakng-loader/#files
# (linux x86_64, linux aarch64, macos arm64, macos x86_64, windows, …).
#
# Usage:
#   kokoro-onnx = import ./default.nix {
#     inherit pkgs;
#     inherit (pkgs) python3Packages;
#   };
#
# The `espeakngWheel` argument lets a caller override the wheel without
# editing this file (e.g. select per pkgs.stdenv.hostPlatform.system).

{
  pkgs,
  python3Packages,

  # Platform-pinned espeakng-loader wheel. Default is the macOS arm64 wheel;
  # OVERRIDE this for your platform. Grab url+hash from PyPI "Download files".
  # To compute the hash: nix store prefetch-file <url>
  espeakngWheel ? {
    url = "https://files.pythonhosted.org/packages/a8/26/258c0cd43b9bc1043301c5f61767d6a6c3b679df82790c9cb43a3277b865/espeakng_loader-0.2.4-py3-none-macosx_11_0_arm64.whl";
    hash = "sha256-0nzcoxESIm5ymdhWLoidPjih5IBVye44G0XWaQcu5Z8=";
  },
}:
let
  # Fetched as a WHEEL, not an sdist: the wheel carries the precompiled
  # libespeak-ng native library. `format = "wheel"` skips the build step.
  espeakng-loader = python3Packages.buildPythonPackage rec {
    pname = "espeakng-loader";
    version = "0.2.4";
    format = "wheel";
    src = pkgs.fetchurl {
      inherit (espeakngWheel) url hash;
    };
  };

  dlinfo = python3Packages.buildPythonPackage rec {
    pname = "dlinfo";
    version = "2.0.0";
    pyproject = true;
    src = python3Packages.fetchPypi {
      inherit pname version;
      hash = "sha256-iKK8BPUdAbxgTNyescPMC96JBXUyymo+caQfYjVDPhc=";
    };
    build-system = with python3Packages; [
      setuptools
      setuptools-scm
    ];
    doCheck = false;
  };

  phonemizer-fork = python3Packages.buildPythonPackage rec {
    pname = "phonemizer-fork";
    version = "3.3.2";
    pyproject = true;
    src = python3Packages.fetchPypi {
      # PyPI normalizes the dist name with an underscore; pname here is the
      # human-readable name, so fetchPypi's pname is overridden explicitly.
      pname = "phonemizer_fork";
      inherit version;
      hash = "sha256-EOFugn0EQ7CHBi4htV6AXACYnPE0Oy6B5zTK5fbAz2k=";
    };
    build-system = [ python3Packages.hatchling ];
    dependencies = with python3Packages; [
      espeakng-loader
      attrs
      dlinfo
      joblib
      segments
      typing-extensions
    ];
    doCheck = false;
  };
in
python3Packages.buildPythonPackage rec {
  pname = "kokoro-onnx";
  version = "0.5.0";
  pyproject = true;

  src = python3Packages.fetchPypi {
    pname = "kokoro_onnx";
    inherit version;
    hash = "sha256-W+sV8IXigo7Y1JP3ksB5r4VxA6stzqoeESsXYFh6yWo=";
  };

  build-system = [ python3Packages.hatchling ];

  dependencies = with python3Packages; [
    numpy
    onnxruntime
    phonemizer-fork
  ];

  doCheck = false;

  meta = with pkgs.lib; {
    description = "TTS inference engine using ONNX runtime (Kokoro)";
    homepage = "https://github.com/thewh1teagle/kokoro-onnx";
    license = licenses.mit;
  };
}
