_final: prev:
let
  metal-cpp = prev.fetchzip {
    url = "https://developer.apple.com/metal/cpp/files/metal-cpp_26.zip";
    hash = "sha256-7n2eI2lw/S+Us6l7YPAATKwcIbRRpaQ8VmES7S8ZjY8=";
  };

  nanobind-src = prev.fetchFromGitHub {
    owner = "wjakob";
    repo = "nanobind";
    rev = "v2.12.0";
    hash = "sha256-s9TshE3V50BtrnVv56j4BxZOloNsOVgi0PUT6xyF7yY=";
    fetchSubmodules = true;
  };

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
      null;

  sdk = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
in
{
  python3Packages = prev.python3Packages.overrideScope (
    _pfinal: pprev: {
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

            env = old.env // {
              CMAKE_ARGS =
                builtins.replaceStrings
                  [ "-DMLX_BUILD_METAL:BOOL=FALSE" ]
                  [
                    "-DMLX_BUILD_METAL:BOOL=TRUE -DMLX_METAL_JIT:BOOL=TRUE -DFETCHCONTENT_SOURCE_DIR_METAL_CPP:FILEPATH=${metal-cpp} -DFETCHCONTENT_SOURCE_DIR_NANOBIND:FILEPATH=${nanobind-src}"
                  ]
                  old.env.CMAKE_ARGS;
            };

            postPatch = ''
              substituteInPlace mlx/backend/cpu/jit_compiler.cpp \
                --replace-fail "g++" "${prev.lib.getExe' prev.stdenv.cc "c++"}"
            ''
            + ''
                substituteInPlace CMakeLists.txt \
                  --replace-fail \
                    'OUTPUT_VARIABLE MLX_METAL_VERSION COMMAND_ERROR_IS_FATAL ANY)' \
                    'OUTPUT_VARIABLE MLX_METAL_VERSION ERROR_QUIET OUTPUT_STRIP_TRAILING_WHITESPACE)
              if(NOT MLX_METAL_VERSION)
                set(MLX_METAL_VERSION 400)
              endif()'
            ''
            + ''
              sed -i '/if(NOT CMAKE_OSX_DEPLOYMENT_TARGET/,/endif()/d' \
                mlx/backend/metal/kernels/CMakeLists.txt
            ''
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
        mlxWithMetal.overrideAttrs (_: {
          __noChroot = true;
        });
    }
  );
}
