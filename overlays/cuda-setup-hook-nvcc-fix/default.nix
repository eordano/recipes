{
  scopes ? [ "cudaPackages" ],
  nvccNativeBuildInputFor ? [ ],
  extraCmakeFlagsFor ? { },
  extraPostInstallFor ? { },
  patchSetupHook ? false,
  requireCudaSupport ? true,
}:

_final: prev:

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

  flagVar =
    f:
    if !(builtins.isString f) then
      null
    else
      let
        m = builtins.match "-D([^:=]+).*" f;
      in
      if m == null then null else builtins.head m;

  applyExtraCmakeFlags =
    name: pkg:
    let
      extras = extraCmakeFlagsFor.${name} or [ ];
      overridden = lib.filter (v: v != null) (map flagVar extras);
    in
    if extras == [ ] then
      pkg
    else
      pkg.overrideAttrs (old: {
        cmakeFlags = lib.filter (f: !(lib.elem (flagVar f) overridden)) (old.cmakeFlags or [ ]) ++ extras;
      });

  applyExtraPostInstall =
    name: pkg:
    let
      extra = extraPostInstallFor.${name} or "";
    in
    if extra == "" then
      pkg
    else
      pkg.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + "\n" + extra;
      });

  targetNames = lib.unique (
    nvccNativeBuildInputFor ++ lib.attrNames extraCmakeFlagsFor ++ lib.attrNames extraPostInstallFor
  );

  fixCudaScope =
    scope:
    scope.overrideScope (
      cudaFinal: cudaPrev:
      lib.genAttrs (lib.filter (name: cudaPrev ? ${name}) targetNames) (
        name:
        applyExtraPostInstall name (
          applyExtraCmakeFlags name (
            if lib.elem name nvccNativeBuildInputFor then
              cudaPrev.${name}.overrideAttrs (old: {
                nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ cudaFinal.cuda_nvcc ];
              })
            else
              cudaPrev.${name}
          )
        )
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
