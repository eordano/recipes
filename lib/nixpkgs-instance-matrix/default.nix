# nixpkgs-instance-matrix
#
# Instantiate the nixpkgs matrix (stable/unstable x CPU/CUDA/aarch64) exactly
# ONCE, up front, and hand every host a cheap selector into the pre-built sets
# instead of having each host re-import (and re-evaluate) nixpkgs.
#
# Importing nixpkgs is expensive: overlays + config get re-run every time. If a
# hundred hosts each do `import nixpkgs { ... }` you pay that cost a hundred
# times. Build the handful of variants you actually use here, once, and select.
#
# Usage (from your flake.nix `let`):
#
#   pkgsLib = import ./lib/nixpkgs-instance-matrix {
#     inherit (inputs) nixpkgs nixpkgs-unstable;
#     defaultConfig = { allowUnfree = true; };
#     cudaConfig    = { cudaSupport = true; cudaCapabilities = [ "8.9" ]; };
#     baseOverlays  = [ (import ./overlays) ];
#     stableOverlays = [ (import ./overlays/from-unstable.nix { unstable = ...; }) ];
#   };
#
#   # per host:
#   pkgs = pkgsLib.pkgsFor { inherit system; extraCfg = { cudaSupport = true; }; };
#
# See README.md for the full rationale and the two traps.

{
  # The two channel inputs. `nixpkgs-unstable` defaults to `nixpkgs` because in
  # many fleets the unstable input `follows` the stable one in flake.lock, so
  # they resolve to the SAME pin. In that setup "unstable" is not a different
  # channel at all -- it is the same source carrying only `baseOverlays`,
  # WITHOUT the extra stable-side overlays that `mkPkgs` layers on. It exists as
  # an escape hatch: a module can grab a lightly-overlaid package when the fully
  # overlaid stable set would hand back a patched/backported variant it does not
  # want. Point `nixpkgs-unstable` at a genuinely different channel if you'd
  # rather it track a newer release.
  nixpkgs,
  nixpkgs-unstable ? nixpkgs,

  # Systems.
  defaultSystem ? "x86_64-linux",
  aarch64System ? "aarch64-linux",

  # nixpkgs `config` for every variant. CUDA variants get `defaultConfig //
  # cudaConfig` so the CUDA-specific keys override.
  defaultConfig ? { allowUnfree = true; },
  cudaConfig ? {
    cudaSupport = true;
    # List only the compute capabilities of GPUs you actually build for --
    # every extra capability multiplies CUDA build time. Some capability +
    # package combinations miscompile (e.g. very new architectures can break
    # opencv under nvcc with a signal 11); pin deliberately and test.
    cudaCapabilities = [ "8.9" ];
    cudaEnableForwardCompat = true;
  },

  # Overlays.
  #
  # baseOverlays: your fleet-wide overlays. TRAP: in `mkPkgs` these are appended
  # LAST, so they apply last and WIN on any name collision with the extra
  # stable overlays below. Keep it that way if you want fleet overrides to be
  # authoritative.
  baseOverlays ? [ ],

  # stableOverlays: extra overlays applied ONLY to the fully-instantiated stable
  # sets (`pkgsDefault` / `pkgsCuda` / `pkgsAarch64`), and placed AHEAD of
  # `baseOverlays` in the list so `baseOverlays` still win on collisions. This
  # is where you'd wire, e.g., "pull these package names from unstable" or
  # locally-built binary overlays.
  stableOverlays ? [ ],

  # cudaOverlays: extra overlays applied ONLY to the unstable CUDA variant --
  # for a package set that is meaningful only when CUDA is on.
  cudaOverlays ? [ ],
}:
let
  # ---- unstable variants (baseOverlays only) ----

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

  # Selector: which pre-built unstable set does this host want?
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

  # ---- stable variants (stableOverlays ahead of baseOverlays) ----

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

  # Selector: which pre-built stable set does this host want?
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
