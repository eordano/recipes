# docker-podman-cdi-rootless
#
# One toggleable NixOS module that flips between Docker and Podman (with
# docker-compat) behind a single flag, while decoupling the "container
# engine choice" from the "CDI / rootless hardening" knobs.
#
# The reusable insight: whichever engine you pick, GPU passthrough via CDI
# and rootless operation are host-independent policy. Wire them once here
# instead of copy-pasting daemon settings into every host.
#
# Trap this encodes: `features.cdi` must be set on BOTH the root daemon and
# the rootless daemon settings. The rootless daemon is a *separate* dockerd
# with its own settings block, so a `features.cdi` on the root daemon alone
# leaves rootless GPU workloads broken.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.virtualisation.containers;
in
{
  options.modules.virtualisation.containers = {
    enable = lib.mkOption {
      description = "Enable a Docker-compatible container engine.";
      type = lib.types.bool;
      default = false;
    };

    usePodman = lib.mkOption {
      description = ''
        Use rootless Podman with the docker CLI compat shim instead of Docker.
        When false, the Docker daemon is used with a rootless companion daemon.
      '';
      type = lib.types.bool;
      default = false;
    };

    enableCdi = lib.mkOption {
      description = ''
        Enable the Container Device Interface (CDI). Required for GPU
        passthrough (e.g. the NVIDIA container toolkit). Harmless without a
        GPU. Applied to BOTH the root and rootless Docker daemons.
      '';
      type = lib.types.bool;
      default = true;
    };

    enableRootless = lib.mkOption {
      description = ''
        Run an additional rootless Docker daemon and export DOCKER_HOST for
        unprivileged users. Note: this does NOT add anyone to the
        root-equivalent `docker` group — that would be gratuitous privilege.
        The rootless socket is the whole point.
      '';
      type = lib.types.bool;
      default = true;
    };

    storageDriver = lib.mkOption {
      description = ''
        Docker storage driver. Leave null to let Docker auto-detect (the safe
        default). Set to "btrfs", "zfs", "overlay2", etc. only when the host's
        backing filesystem actually supports it — a mismatched driver here
        will fail to start the daemon.
      '';
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "overlay2";
    };

    podmanExtraPackages = lib.mkOption {
      description = ''
        Extra packages made available to Podman. Add the userspace tools for
        your backing filesystem here (e.g. [ pkgs.zfs ] on ZFS-backed hosts)
        so Podman can drive that storage graph driver.
      '';
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.zfs ]";
    };

    dns = lib.mkOption {
      description = ''
        DNS resolvers for the rootless daemon's containers. The rootless
        daemon does not inherit the host's resolver the way the root daemon
        does, so set this explicitly. Override with your LAN resolver on hosts
        that must resolve internal names.
      '';
      type = lib.types.listOf lib.types.str;
      default = [ "1.1.1.1" ];
      example = lib.literalExpression ''[ "192.0.2.1" ]'';
    };

    autoPrune = lib.mkOption {
      description = "Periodically `docker system prune` to reclaim disk.";
      type = lib.types.bool;
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    # --- Podman branch: rootless by design, docker CLI compat shim on ---
    virtualisation.podman = lib.mkIf cfg.usePodman {
      enable = true;
      dockerCompat = true;
      extraPackages = cfg.podmanExtraPackages;
    };

    # --- Docker branch ---
    virtualisation.docker = lib.mkIf (!cfg.usePodman) {
      enable = true;
      enableOnBoot = true;
      autoPrune.enable = cfg.autoPrune;
      storageDriver = cfg.storageDriver;

      # Root daemon settings.
      daemon.settings = lib.mkIf cfg.enableCdi {
        features.cdi = true;
      };

      # Rootless companion daemon — a SEPARATE dockerd with its OWN settings.
      rootless = lib.mkIf cfg.enableRootless {
        enable = true;
        setSocketVariable = true;
        daemon.settings = {
          # CDI must be repeated here; the root daemon's setting does not
          # carry over to the rootless daemon. This is the load-bearing trap.
          features.cdi = lib.mkIf cfg.enableCdi true;
          dns = cfg.dns;
        };
      };
    };
  };
}
