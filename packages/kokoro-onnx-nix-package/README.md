# kokoro-onnx-nix-package

Package [kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx) — an
ONNX-runtime text-to-speech engine — for Nix, when neither it nor several of
its dependencies exist in nixpkgs.

## The problem

`kokoro-onnx` is not in nixpkgs. Neither are three packages in its dependency
closure:

- **phonemizer-fork** — a maintained fork of `phonemizer` (grapheme → phoneme)
- **espeakng-loader** — locates and loads the `espeak-ng` shared library
- **dlinfo** — a tiny `ctypes` helper that phonemizer-fork depends on

There is no overlay to lean on, so all four are hand-rolled with
`buildPythonPackage` straight from PyPI. Three of them (`kokoro-onnx`,
`dlinfo`, `phonemizer-fork`) are ordinary pure-Python `pyproject` sdists and
build the boring way.

## The trap: espeakng-loader must be fetched as a wheel, not an sdist

`espeakng-loader` bundles a **precompiled native `libespeak-ng`** inside its
wheel. There is one wheel per platform. The PyPI **sdist does not build the
native library** — so the reflexive `fetchPypi { inherit pname version; }`
(which grabs the sdist) gives you a package that imports but has no working
espeak-ng behind it.

The fix is to fetch the **platform-matching wheel** explicitly:

```nix
espeakng-loader = python3Packages.buildPythonPackage {
  pname = "espeakng-loader";
  version = "0.2.4";
  format = "wheel";                 # <- not an sdist build
  src = pkgs.fetchurl {
    url  = ".../espeakng_loader-0.2.4-py3-none-<platform>.whl";
    hash = "sha256-...";
  };
};
```

Because the wheel is platform-specific, **you must pick the wheel that matches
the machine you build/run on.** The default in `default.nix` is the macOS
arm64 wheel — override it for Linux x86_64, Linux aarch64, etc.

## Two other small gotchas

- **PyPI name normalization.** `phonemizer-fork` and `kokoro-onnx` are
  published on PyPI under underscored dist names (`phonemizer_fork`,
  `kokoro_onnx`). `fetchPypi` defaults `pname` to the value you pass, so pass
  the underscored form to `pname` (or it 404s).
- **`doCheck = false`** on all of them. Their test suites want network access
  and extra tooling that add nothing to a package build.

## Usage

```nix
let
  kokoro-onnx = import ./default.nix {
    inherit pkgs;
    inherit (pkgs) python3Packages;
  };
in
  # e.g. pkgs.python3.withPackages (ps: [ kokoro-onnx ])
```

### Selecting the wheel for your platform

Override `espeakngWheel`. Get the URL and hash from the "Download files" tab on
<https://pypi.org/project/espeakng-loader/#files>; compute the hash with
`nix store prefetch-file <url>`.

```nix
import ./default.nix {
  inherit pkgs;
  inherit (pkgs) python3Packages;
  espeakngWheel = {
    url  = "https://files.pythonhosted.org/.../espeakng_loader-0.2.4-py3-none-manylinux_2_17_x86_64.manylinux2014_x86_64.whl";
    hash = "sha256-...";
  };
}
```

You can also drive this off `pkgs.stdenv.hostPlatform.system` with an attrset
mapping each system to its wheel, so a multi-arch build picks the right one
automatically.

## Caveats

- Versions and hashes are pinned to a point in time (kokoro-onnx 0.5.0,
  espeakng-loader 0.2.4, phonemizer-fork 3.3.2, dlinfo 2.0.0). Bump and
  re-hash as upstream moves; the wheel URL changes with every espeakng-loader
  release.
- If any of these land in nixpkgs later, drop the corresponding `let` binding
  and use the nixpkgs attribute instead.
- The Kokoro voice/model ONNX files themselves are not packaged here — this is
  just the inference library.
