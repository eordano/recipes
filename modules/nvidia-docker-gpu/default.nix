# nvidia-docker-gpu — GPU passthrough to Docker on NixOS
#
# GPU passthrough to `docker run --gpus all ...` on NixOS is a TWO-PART switch,
# and enabling only one half silently gives you a Docker that can't see the GPU:
#
#   1. hardware.nvidia-container-toolkit.enable — installs the CDI spec generator
#      that describes the host GPU as a Container Device Interface device.
#   2. A Docker daemon with the `cdi` feature gate turned ON — without it dockerd
#      ignores the generated CDI spec, and `--gpus` / `--device nvidia.com/gpu=all`
#      resolve to nothing.
#
# A common shape for this is a one-line "joint enable" module that flips both
# switches but delegates the load-bearing daemon config to a separate Docker
# module — and then that daemon config is easy to get wrong or forget. This
# module INLINES the daemon config (CDI gate + the rootless-DNS fix), so
# importing this single module is genuinely enough to get working GPU containers.
{
  config,
  lib,
  ...
}:
let
  cfg = config.virtualisation.nvidiaDockerGpu;
in
{
  options.virtualisation.nvidiaDockerGpu = {
    enable = lib.mkEnableOption "Docker configured for NVIDIA GPU passthrough (CDI)";

    rootless = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Also run a rootless Docker daemon for the invoking user. Rootless is the
        safer default (no docker-group == root-equivalent handout), and the CDI
        feature gate is applied to the rootless daemon too.
      '';
    };

    rootlessDns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "1.1.1.1" ];
      description = ''
        DNS servers for the ROOTLESS daemon's default bridge network. The trap:
        the rootless network stack does not inherit the host's /etc/resolv.conf
        the way the rootful daemon does, so containers on the rootless daemon get
        no working resolver unless you pin one here. Use your own resolver if you
        do not want to hardcode a public one.
      '';
    };

    storageDriver = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "zfs";
      description = ''
        Force a specific Docker storage driver. Leave `null` to let NixOS pick.
        Set this (e.g. "zfs") when Docker's data-root lives on a filesystem whose
        graphdriver must be chosen explicitly — a mismatched driver makes dockerd
        fail to start ("wrong filesystem") rather than fall back gracefully.
      '';
    };

    dataRoot = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/persist/docker";
      description = ''
        Override Docker's data-root. Useful on impermanent / rollback roots where
        `/var/lib/docker` would be wiped on boot — point it at a durable dataset.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Half 1: generate the CDI spec describing the host GPU.
    hardware.nvidia-container-toolkit.enable = true;

    # Half 2: a Docker daemon that actually honours that CDI spec.
    virtualisation.docker = {
      enable = true;
      enableOnBoot = true;

      # THE load-bearing line: without the cdi feature gate, dockerd ignores the
      # CDI device spec and `--gpus all` sees no GPU.
      daemon.settings = {
        features.cdi = true;
      } // lib.optionalAttrs (cfg.dataRoot != null) {
        data-root = cfg.dataRoot;
      };

      storageDriver = lib.mkIf (cfg.storageDriver != null) cfg.storageDriver;

      rootless = lib.mkIf cfg.rootless {
        enable = true;
        setSocketVariable = true;
        daemon.settings = {
          # The gate must be repeated for the rootless daemon — it is a separate
          # dockerd with its own config, it does not inherit the rootful one.
          features.cdi = true;
          # ...and its own DNS, or rootless containers cannot resolve names.
          dns = cfg.rootlessDns;
        };
      };
    };
  };
}
