{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.modules.nvidia;

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

  kernel_6_19_patch = pkgs.fetchpatch {
    url = "https://github.com/CachyOS/CachyOS-PKGBUILDS/raw/d5629d64ac1f9e298c503e407225b528760ffd37/nvidia/nvidia-utils/kernel-6.19.patch";
    hash = "sha256-YuJjSUXE6jYSuZySYGnWSNG5sfVei7vvxDcHx3K+IN4=";
  };

  kernel_6_18_stdarg_patch = ./nvidia-kernel-6.18-stdarg.patch;

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
      patchesOpen = [
        kernel_6_19_patch
        kernel_6_18_stdarg_patch
      ];
    };
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

      nvidia = {
        modesetting.enable = true;

        powerManagement.enable = true;
        powerManagement.finegrained = false;

        forceFullCompositionPipeline = true;

        inherit (cfg) open;

        nvidiaSettings = false;

        package = driverVersions.${cfg.driverVersion};
      }
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
        initrd.kernelModules = modulesToLoad;
        kernelModules = modulesToLoad;
      };
  };
}
