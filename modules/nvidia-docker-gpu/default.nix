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
        graphdriver must be chosen explicitly -- a mismatched driver makes dockerd
        fail to start ("wrong filesystem") rather than fall back gracefully.
      '';
    };

    dataRoot = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/persist/docker";
      description = ''
        Override Docker's data-root. Useful on impermanent / rollback roots where
        `/var/lib/docker` would be wiped on boot -- point it at a durable dataset.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    hardware.nvidia-container-toolkit.enable = true;

    virtualisation.docker = {
      enable = true;
      enableOnBoot = true;

      daemon.settings = {
        features.cdi = true;
      }
      // lib.optionalAttrs (cfg.dataRoot != null) {
        data-root = cfg.dataRoot;
      };

      storageDriver = lib.mkIf (cfg.storageDriver != null) cfg.storageDriver;

      rootless = lib.mkIf cfg.rootless {
        enable = true;
        setSocketVariable = true;
        daemon.settings = {
          features.cdi = true;
          dns = cfg.rootlessDns;
        };
      };
    };
  };
}
