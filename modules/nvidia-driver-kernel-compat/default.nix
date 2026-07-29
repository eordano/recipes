# nvidia-driver-kernel-compat
#
# A NixOS module that pins a specific NVIDIA proprietary/open driver version and
# carries version-specific kernel build patches, so a bleeding-edge kernel
# (6.18 / 6.19 / newer) does not silently break the out-of-tree module build.
#
# Why this exists (the traps):
#
#   1. nixpkgs' `nvidiaPackages.latest`/`production`/`beta` float. A routine
#      `nixpkgs` bump can jump you to a driver release that regresses YOUR
#      workload (a hung GPU handoff, a broken VM passthrough, a new modeset
#      quirk). Pinning an exact version — with its own hashes — makes the driver
#      an explicit, reviewable choice instead of a side effect of a channel bump.
#
#   2. Newer kernels break the NVIDIA kernel modules at COMPILE time, before any
#      of nixpkgs' packaged patch set catches up:
#        - kernel 6.18 moved `va_start`/`va_arg` plumbing so the module's
#          `nv-linux.h` must `#include <linux/stdarg.h>` explicitly (the bundled
#          stdarg patch below).
#        - kernel 6.19 needs a further source fixup (fetched from CachyOS'
#          packaging, which tends to carry these fixes first).
#      Without the matching patch the driver derivation fails to build and the
#      whole system rebuild fails. The patches are attached per-version via
#      `patchesOpen`, so each pinned driver carries exactly the fixups its
#      source needs for the kernel you run it against.
#
#   3. Open vs proprietary kernel modules. The open modules are REQUIRED on
#      Blackwell (RTX 50xx) and later, recommended on Turing+ (RTX 20xx / GTX
#      16xx and newer). Only pre-Turing GPUs need the legacy proprietary module.
#      Default to open; flip `open = false` only for old cards.
#
# Usage:
#
#   imports = [ ./nvidia-driver-kernel-compat ];
#   modules.nvidia = {
#     enable = true;
#     driverVersion = "575";   # pin, or "latest" to track nixpkgs
#     open = true;             # Blackwell/Turing+; false for pre-Turing
#     prime.enable = false;    # true on hybrid laptops (iGPU + dGPU)
#   };
#
# The pinned `driverVersions` entries below are concrete, working EXAMPLES.
# Update their `version` + hashes to the release you want to pin. To fetch the
# hashes for a new version, add the entry with dummy hashes and let the build
# tell you the correct `got:` values, or use nixpkgs' driver metadata.
#
# `patchesOpen` here patches the OPEN kernel-module source tree. If you pin
# `open = false` (legacy proprietary module) you would instead need the
# equivalent `patches` argument — the proprietary source has a different layout,
# so the open-module patches do not apply to it unchanged.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.modules.nvidia;

  # Thin wrapper over the kernel package set's `mkDriver`, so each pinned entry
  # is just its version + hashes + any per-kernel patches.
  mkDriver =
    {
      version,
      sha256_64bit,
      sha256_aarch64,
      openSha256,
      settingsSha256,
      persistencedSha256,
      patchesOpen ? [ ],
    }:
    config.boot.kernelPackages.nvidiaPackages.mkDriver {
      inherit
        version
        sha256_64bit
        sha256_aarch64
        openSha256
        settingsSha256
        persistencedSha256
        patchesOpen
        ;
      url = "https://us.download.nvidia.com/XFree86/Linux-x86_64/${version}/NVIDIA-Linux-x86_64-${version}.run";
    };

  # kernel 6.19 build fixup — CachyOS packages these ahead of upstream nixpkgs.
  # Pin the revision + hash so the fetch is reproducible.
  kernel_6_19_patch = pkgs.fetchpatch {
    url = "https://github.com/CachyOS/CachyOS-PKGBUILDS/raw/d5629d64ac1f9e298c503e407225b528760ffd37/nvidia/nvidia-utils/kernel-6.19.patch";
    hash = "sha256-YuJjSUXE6jYSuZySYGnWSNG5sfVei7vvxDcHx3K+IN4=";
  };

  # kernel 6.18 build fixup — adds the missing <linux/stdarg.h> include.
  kernel_6_18_stdarg_patch = ./nvidia-kernel-6.18-stdarg.patch;

  # Pinned driver releases. Each carries the patches its source needs to build
  # against the kernel you run. These are examples — swap versions/hashes freely.
  driverVersions = {
    "575" = mkDriver {
      version = "575.64.05";
      sha256_64bit = "sha256-hfK1D5EiYcGRegss9+H5dDr/0Aj9wPIJ9NVWP3dNUC0=";
      sha256_aarch64 = "sha256-GRE9VEEosbY7TL4HPFoyo0Ac5jgBHsZg9sBKJ4BLhsA=";
      openSha256 = "sha256-mcbMVEyRxNyRrohgwWNylu45vIqF+flKHnmt47R//KU=";
      settingsSha256 = "sha256-o2zUnYFUQjHOcCrB0w/4L6xI1hVUXLAWgG2Y26BowBE=";
      persistencedSha256 = "sha256-2g5z7Pu8u2EiAh5givP5Q1Y4zk4Cbb06W37rf768NFU=";
      patchesOpen = [ kernel_6_18_stdarg_patch ];
    };
    "570" = mkDriver {
      version = "570.195.03";
      sha256_64bit = "sha256-1H3oHZpRNJamCtyc+nL+nhYsZfJyL7lgxPUxvXrF3B4=";
      sha256_aarch64 = "sha256-o4rgB6vo+Cv90lJywovIyVARRGS3R15zYQUj+f1nzWQ=";
      openSha256 = "sha256-vCBB/UJgVKHlSEWdgoF45lODr3YJmR6JwjrwWgWszBw=";
      settingsSha256 = "sha256-mjKkMEPV6W69PO8jKAKxAS861B82CtCpwVTeNr5CqUY=";
      persistencedSha256 = "sha256-BMpo2PIabhHjZQqUQi/W5DYhgAPmfCdFvXdN6ND2Bfs=";
      patchesOpen = [ kernel_6_18_stdarg_patch ];
    };
    "590" = mkDriver {
      version = "590.48.01";
      sha256_64bit = "sha256-ueL4BpN4FDHMh/TNKRCeEz3Oy1ClDWto1LO/LWlr1ok=";
      sha256_aarch64 = "sha256-FOz7f6pW1NGM2f74kbP6LbNijxKj5ZtZ08bm0aC+/YA=";
      openSha256 = "sha256-hECHfguzwduEfPo5pCDjWE/MjtRDhINVr4b1awFdP44=";
      settingsSha256 = "sha256-NWsqUciPa4f1ZX6f0By3yScz3pqKJV1ei9GvOF8qIEE=";
      persistencedSha256 = "sha256-wsNeuw7IaY6Qc/i/AzT/4N82lPjkwfrhxidKWUtcwW8=";
      # Newer driver source against a newer kernel needs BOTH fixups.
      patchesOpen = [
        kernel_6_19_patch
        kernel_6_18_stdarg_patch
      ];
    };
    # Escape hatch: whatever nixpkgs currently ships. Unpinned by design.
    "latest" = config.boot.kernelPackages.nvidiaPackages.latest;
  };
in
{
  options.modules.nvidia = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable using a discrete NVIDIA GPU.";
    };
    driverVersion = lib.mkOption {
      type = lib.types.enum [
        "latest"
        "590"
        "575"
        "570"
      ];
      default = "latest";
      description = ''
        Which pinned NVIDIA driver to use, or "latest" to track nixpkgs.
        Pin an exact version so a nixpkgs channel bump cannot silently move you
        to a driver release that regresses your workload.
      '';
    };
    open = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Use the NVIDIA open kernel modules. Required for Blackwell (RTX 50xx+),
        recommended for Turing+ (RTX 20xx / GTX 16xx and newer). Set to false
        only for pre-Turing GPUs (legacy proprietary module).
      '';
    };
    prime = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable NVIDIA PRIME render offload for hybrid graphics (laptop iGPU + dGPU).";
      };
      intelBusId = lib.mkOption {
        type = lib.types.str;
        default = "PCI:0:2:0";
        example = "PCI:0:2:0";
        description = "PCI bus ID of the integrated GPU. Find it with `lspci`.";
      };
      nvidiaBusId = lib.mkOption {
        type = lib.types.str;
        default = "PCI:1:0:0";
        example = "PCI:1:0:0";
        description = "PCI bus ID of the discrete NVIDIA GPU. Find it with `lspci`.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.xserver.videoDrivers = [
      "modesetting"
      "nvidia"
    ];

    hardware = {
      graphics = {
        enable = true;
        enable32Bit = true;
        extraPackages = with pkgs; [ nvidia-vaapi-driver ];
      };

      nvidia =
        {
          modesetting.enable = true;

          powerManagement.enable = true;
          powerManagement.finegrained = false;

          forceFullCompositionPipeline = true;

          open = cfg.open;

          # nvidia-settings GUI is off by default; flip on if you want it.
          nvidiaSettings = false;

          package = driverVersions.${cfg.driverVersion};
        }
        # Only wire PRIME when explicitly enabled — attaching PRIME keeps the
        # driver bound in a way that fights dynamic VFIO rebind / GPU passthrough
        # setups, so it must stay off unless you actually render-offload.
        // lib.optionalAttrs cfg.prime.enable {
          prime = {
            intelBusId = cfg.prime.intelBusId;
            nvidiaBusId = cfg.prime.nvidiaBusId;
            reverseSync.enable = true;
            offload = {
              enable = true;
              enableOffloadCmd = true;
            };
          };
        };
    };

    boot =
      let
        modulesToLoad = [
          "nvidia"
          "nvidia_modeset"
          "nvidia_uvm"
          "nvidia_drm"
          "i2c-nvidia_gpu"
        ];
      in
      {
        kernelParams = [
          "nvidia-drm.fbdev=1"
          "nvidia-drm.modeset=1"
          "fbdev=1"
        ];
        # Load in initrd too so the framebuffer comes up on the NVIDIA GPU early
        # (avoids a flickery/black handoff from simpledrm).
        initrd.kernelModules = modulesToLoad;
        kernelModules = modulesToLoad;
      };
  };
}
