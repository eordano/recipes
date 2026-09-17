{
  nixpkgs,
  nixpkgs-unstable ? nixpkgs,

  defaultSystem ? "x86_64-linux",
  aarch64System ? "aarch64-linux",

  defaultConfig ? {
    allowUnfree = true;
  },
  cudaConfig ? {
    cudaSupport = true;
    cudaCapabilities = [ "8.9" ];
    cudaEnableForwardCompat = true;
  },

  baseOverlays ? [ ],

  stableOverlays ? [ ],

  cudaOverlays ? [ ],
}:
let

  mkUnstable =
    system:
    import nixpkgs-unstable {
      inherit system;
      overlays = baseOverlays;
      config = defaultConfig;
    };

  mkUnstableCuda =
    system:
    import nixpkgs-unstable {
      inherit system;
      overlays = baseOverlays ++ cudaOverlays;
      config = defaultConfig // cudaConfig;
    };

  unstableDefault = mkUnstable defaultSystem;
  unstableCuda = mkUnstableCuda defaultSystem;
  unstableAarch64 = mkUnstable aarch64System;

  unstableFor =
    {
      extraCfg ? { },
      system ? defaultSystem,
    }:
    if (extraCfg.cudaSupport or false) then
      unstableCuda
    else if system == aarch64System then
      unstableAarch64
    else
      unstableDefault;

  mkPkgs =
    {
      system,
      cuda ? false,
    }:
    import nixpkgs {
      inherit system;
      config = defaultConfig // (if cuda then cudaConfig else { });
      overlays = stableOverlays ++ baseOverlays;
    };

  pkgsDefault = mkPkgs { system = defaultSystem; };
  pkgsCuda = mkPkgs {
    system = defaultSystem;
    cuda = true;
  };
  pkgsAarch64 = mkPkgs { system = aarch64System; };

  pkgsFor =
    {
      extraCfg ? { },
      system ? defaultSystem,
    }:
    if (extraCfg.cudaSupport or false) then
      pkgsCuda
    else if system == aarch64System then
      pkgsAarch64
    else
      pkgsDefault;
in
{
  inherit
    mkUnstable
    mkUnstableCuda
    unstableFor
    unstableDefault
    unstableCuda
    unstableAarch64
    mkPkgs
    pkgsDefault
    pkgsCuda
    pkgsAarch64
    pkgsFor
    ;
}
