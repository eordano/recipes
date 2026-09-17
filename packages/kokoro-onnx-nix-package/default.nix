{
  pkgs,
  python3Packages,

  espeakngWheel ? {
    url = "https://files.pythonhosted.org/packages/a8/26/258c0cd43b9bc1043301c5f61767d6a6c3b679df82790c9cb43a3277b865/espeakng_loader-0.2.4-py3-none-macosx_11_0_arm64.whl";
    hash = "sha256-0nzcoxESIm5ymdhWLoidPjih5IBVye44G0XWaQcu5Z8=";
  },
}:
let
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
