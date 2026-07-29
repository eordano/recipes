{
  scopes ? [ "cudaPackages" ],
  nvccNativeBuildInputFor ? [
    "cudnn-frontend"
    "cutlass"
  ],
  patchSetupHook ? true,
  requireCudaSupport ? true,
}:

final: prev:

let
  inherit (prev) lib;

  hookFix = ''
    cat >> "$out/nix-support/setup-hook" <<'HOOKFIX'

    setupCUDAToolkit_ROOT() {
      (("''${NIX_DEBUG:-0}" >= 1)) && echo "setupCUDAToolkit_ROOT: cudaHostPathsSeen=''${!cudaHostPathsSeen[*]}" >&2

      for path in "''${!cudaHostPathsSeen[@]}"; do
        addToSearchPathWithCustomDelimiter ";" CUDAToolkit_ROOT "$path"
        if [[ -d "$path/include" ]]; then
          addToSearchPathWithCustomDelimiter ";" CUDAToolkit_INCLUDE_DIR "$path/include"
        fi
      done

      local nvccExe
      if nvccExe="$(type -P nvcc)"; then
        addToSearchPathWithCustomDelimiter ";" CUDAToolkit_ROOT "''${nvccExe%/bin/nvcc}"
      fi

      if [[ -n ''${CUDAToolkit_INCLUDE_DIR-} ]]; then
        cmakeFlagsArray+=("-DCUDAToolkit_INCLUDE_DIR=''${CUDAToolkit_INCLUDE_DIR}")
      fi
      if [[ -n ''${CUDAToolkit_ROOT-} ]]; then
        cmakeFlagsArray+=("-DCUDAToolkit_ROOT=''${CUDAToolkit_ROOT}")
      fi
    }
    HOOKFIX
  '';

  fixCudaScope =
    scope:
    scope.overrideScope (
      cudaFinal: cudaPrev:
      lib.genAttrs (lib.filter (name: cudaPrev ? ${name}) nvccNativeBuildInputFor) (
        name:
        cudaPrev.${name}.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ cudaFinal.cuda_nvcc ];
        })
      )
      // lib.optionalAttrs patchSetupHook {
        setupCudaHook = cudaPrev.setupCudaHook.overrideAttrs (old: {
          buildCommand = (old.buildCommand or "") + hookFix;
        });
      }
    );
in

if requireCudaSupport && !(prev.config.cudaSupport or false) then
  { }
else
  lib.genAttrs (lib.filter (name: prev ? ${name}) scopes) (name: fixCudaScope prev.${name})
