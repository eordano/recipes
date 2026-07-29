# mlx-metal-gpu-overlay
#
# Build MLX (ml-explore/mlx) with Metal GPU support under Nix on Apple Silicon.
#
# The trap: nixpkgs ships MLX CPU-only because the Metal shader compiler
# (`metal` / `metallib`) is normally invoked through `xcrun`, and `xcrun` is
# invisible inside the Nix build sandbox. This overlay discovers the real
# MetalToolchain cryptex mount at *eval time*, rewrites MLX's build scripts to
# call `metal`/`metallib` directly against that toolchain plus the Xcode SDK,
# and sets `__noChroot = true` because the Metal compiler needs the real
# toolchain and SDK on disk. If the toolchain mount is absent the overlay
# quietly falls back to a plain CPU-only build.
#
# Usage: add to `nixpkgs.overlays` on an aarch64-darwin config, then use
# `python3Packages.mlx`. Requires:
#   - Xcode installed (for the MacOSX SDK), and
#   - the Metal toolchain present (Xcode component; the cryptex mount below).
#   - the sandbox relaxation `__noChroot` honored — set in nix.conf:
#       sandbox = relaxed          # or  false
#   Nothing here depends on any particular host, user, or network.
#
# Pin the versions/hashes below to whatever MLX release you want.

final: prev:
let
  # Apple's metal-cpp headers. FetchContent inside MLX's CMake wants to grab
  # these from the network at build time; we pre-fetch and point at the store.
  metal-cpp = prev.fetchzip {
    url = "https://developer.apple.com/metal/cpp/files/metal-cpp_26.zip";
    hash = "sha256-7n2eI2lw/S+Us6l7YPAATKwcIbRRpaQ8VmES7S8ZjY8=";
  };

  # nanobind (Python bindings). Same story: pre-fetch so CMake FetchContent
  # resolves it from the store instead of hitting the network in-sandbox.
  nanobind-src = prev.fetchFromGitHub {
    owner = "wjakob";
    repo = "nanobind";
    rev = "v2.12.0";
    hash = "sha256-s9TshE3V50BtrnVv56j4BxZOloNsOVgi0PUT6xyF7yY=";
    fetchSubmodules = true;
  };

  # The Metal toolchain ships as a cryptex ("MobileAsset") that macOS mounts
  # under this directory. Its exact subdirectory name carries a version suffix
  # that changes across OS/Xcode updates, so we discover it at eval time rather
  # than hardcoding it. readDir here is an impure-ish eval read of the live
  # filesystem — that is deliberate; it is how we find the toolchain path.
  cryptexdMnt = "/var/run/com.apple.security.cryptexd/mnt";
  metalToolchainDir =
    let
      entries = builtins.attrNames (builtins.readDir cryptexdMnt);
      toolchains = builtins.filter (
        e: prev.lib.hasPrefix "com.apple.MobileAsset.MetalToolchain-" e
      ) entries;
    in
    if toolchains != [ ] then
      "${cryptexdMnt}/${builtins.head toolchains}/Metal.xctoolchain/usr/bin"
    else
      # Toolchain not mounted → metalToolchainDir stays null and the patches
      # below are skipped, leaving MLX to build CPU-only.
      null;

  # The Metal compiler needs an -isysroot pointing at the real MacOSX SDK.
  sdk = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
in
{
  python3Packages = prev.python3Packages.overrideScope (
    pfinal: pprev: {
      mlx =
        let
          mlxWithMetal = pprev.mlx.overridePythonAttrs (old: {
            version = "0.31.1";
            src = prev.fetchFromGitHub {
              owner = "ml-explore";
              repo = "mlx";
              tag = "v0.31.1";
              hash = "sha256-PiNk/MdMw9Vpat2KuslBTyaFuK+mJ4UvwJqBnysvvUU=";
            };

            build-system = [
              pprev.cmake
              pprev.setuptools
              pprev.typing-extensions
            ];

            # Flip the nixpkgs default (Metal OFF) to ON, enable the Metal JIT,
            # and hand CMake FetchContent our pre-fetched sources so it does no
            # network access during the build.
            env = old.env // {
              CMAKE_ARGS =
                builtins.replaceStrings
                  [ "-DMLX_BUILD_METAL:BOOL=FALSE" ]
                  [
                    "-DMLX_BUILD_METAL:BOOL=TRUE -DMLX_METAL_JIT:BOOL=TRUE -DFETCHCONTENT_SOURCE_DIR_METAL_CPP:FILEPATH=${metal-cpp} -DFETCHCONTENT_SOURCE_DIR_NANOBIND:FILEPATH=${nanobind-src}"
                  ]
                  old.env.CMAKE_ARGS;
            };

            postPatch =
              # (1) CPU JIT compiler hardcodes "g++"; point it at the Nix stdenv
              #     C++ compiler so the CPU path also builds hermetically.
              ''
                substituteInPlace mlx/backend/cpu/jit_compiler.cpp \
                  --replace-fail "g++" "${prev.lib.getExe' prev.stdenv.cc "c++"}"
              ''
              # (2) MLX derives its Metal version by shelling out to xcrun; that
              #     fails in-sandbox and is FATAL. Make it non-fatal and default
              #     to a sane version so configuration proceeds.
              + ''
                  substituteInPlace CMakeLists.txt \
                    --replace-fail \
                      'OUTPUT_VARIABLE MLX_METAL_VERSION COMMAND_ERROR_IS_FATAL ANY)' \
                      'OUTPUT_VARIABLE MLX_METAL_VERSION ERROR_QUIET OUTPUT_STRIP_TRAILING_WHITESPACE)
                if(NOT MLX_METAL_VERSION)
                  set(MLX_METAL_VERSION 400)
                endif()'
              ''
              # (3) Drop the deployment-target guard that aborts when
              #     CMAKE_OSX_DEPLOYMENT_TARGET is unset in the sandbox.
              + ''
                sed -i '/if(NOT CMAKE_OSX_DEPLOYMENT_TARGET/,/endif()/d' \
                  mlx/backend/metal/kernels/CMakeLists.txt
              ''
              # (4) The core fix: replace `xcrun -sdk macosx metal[lib]` shellouts
              #     with direct calls to the discovered toolchain binaries against
              #     the Xcode SDK. `env -u MACOSX_DEPLOYMENT_TARGET` avoids a stray
              #     deployment-target from the sandbox env breaking the compiler.
              #     Only applied when the toolchain was found.
              + prev.lib.optionalString (metalToolchainDir != null) ''
                metal=${metalToolchainDir}/metal
                metallib=${metalToolchainDir}/metallib
                sdk=${sdk}
                sed -i "s|xcrun -sdk macosx metal |env -u MACOSX_DEPLOYMENT_TARGET $metal -isysroot $sdk |g" \
                  mlx/backend/metal/kernels/CMakeLists.txt
                sed -i "s|xcrun -sdk macosx metallib |$metallib |g" \
                  mlx/backend/metal/kernels/CMakeLists.txt
                echo "Patched metal shader compiler: $metal"
              ''
              # (5) Same substitution for the preamble generator script, which
              #     has its own hardcoded `xcrun ... metal` invocation.
              + prev.lib.optionalString (metalToolchainDir != null) ''
                metal=${metalToolchainDir}/metal
                sdk=${sdk}
                sed -i "s|CCC=\"xcrun -sdk macosx metal -x metal\"|CCC=\"env -u MACOSX_DEPLOYMENT_TARGET $metal -isysroot $sdk -x metal\"|g" \
                  mlx/backend/metal/make_compiled_preamble.sh
                echo "Patched make_compiled_preamble.sh: CCC uses direct metal path"
              '';

            doCheck = false;
          });
        in
        # __noChroot lets the build reach the real Metal toolchain + SDK on disk.
        # Requires `sandbox = relaxed` (or false) in the daemon's nix.conf; the
        # daemon ignores __noChroot when full sandboxing is enforced.
        mlxWithMetal.overrideAttrs (_: {
          __noChroot = true;
        });
    }
  );
}
