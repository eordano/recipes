{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib)
    concatMap
    concatStringsSep
    mkEnableOption
    mkForce
    mkIf
    mkMerge
    mkOption
    mkPackageOption
    optionalString
    optionals
    types
    ;

  cfg = config.boot.mirroredEsp;
  sdb = config.boot.loader.systemd-boot;

  esp = cfg.primary.mountPoint;
  cp = "${cfg.coreutilsPackage}/bin/cp";
  rsync = "${cfg.rsyncPackage}/bin/rsync";

  isNixosEntryName = n: lib.hasPrefix "nixos-" n && lib.hasSuffix ".conf" n;
  badEntryNames = builtins.filter isNixosEntryName cfg.recovery.entryFiles;

  dir = cfg.recovery.directory;

  kernelBlock = optionals (cfg.recovery.efiFiles != [ ]) (
    [ "  ${cp} -f \\" ]
    ++ map (f: "    ${dir}/${f} \\") cfg.recovery.efiFiles
    ++ [ "    ${esp}/EFI/nixos/" ]
  );

  entryBlocks = concatMap (e: [
    "  ${cp} -f \\"
    "    ${dir}/${e} \\"
    "    ${esp}/loader/entries/${e}"
  ]) cfg.recovery.entryFiles;

  recoveryLines = optionals cfg.recovery.enable (
    [ "if [ -d ${dir} ]; then" ] ++ kernelBlock ++ entryBlocks ++ [ "fi" ]
  );

  rsyncArgs = cfg.rsyncFlags ++ map (p: "--exclude=${p}") cfg.rsyncExcludes;

  mirrorLines = optionals cfg.mirror.enable [
    "${rsync} ${concatStringsSep " " rsyncArgs} ${esp}/ ${cfg.mirror.mountPoint}/"
  ];

  installLines = recoveryLines ++ mirrorLines;

  installScript = optionalString (installLines != [ ]) (concatStringsSep "\n" installLines + "\n");

  barrierUnit = barrier: {
    description = "Wait for ZFS native mount at ${barrier.mountpoint}";
    after = barrier.importUnits;
    requires = barrier.importUnits;
    inherit (barrier) wantedBy;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ cfg.utilLinuxPackage ];
    script = ''
      attempts=0
      delay=1
      while [ $attempts -lt ${toString barrier.attempts} ]; do
        if mountpoint -q "${barrier.mountpoint}"; then
          echo "${barrier.mountpoint} is mounted"
          exit 0
        fi
        attempts=$((attempts + 1))
        echo "Waiting for ${barrier.mountpoint} (attempt $attempts/${toString barrier.attempts}, sleeping ''${delay}s)"
        sleep $delay
        delay=$((delay * 2))
      done
      echo "ERROR: ${barrier.mountpoint} not mounted after ${toString barrier.attempts} attempts"
      exit 1
    '';
  };

  barrierType = types.submodule {
    options = {
      mountpoint = mkOption {
        type = types.str;
        example = "/tank";
        description = ''
          Absolute path that must be a real mountpoint before the barrier unit
          reports success. Checked with `mountpoint -q`, which tests the mount
          table — not `test -d`, which succeeds on the empty directory left
          behind by a pool that failed to import.
        '';
      };

      importUnits = mkOption {
        type = types.listOf types.str;
        example = [ "zfs-import-tank.service" ];
        description = ''
          Units placed in BOTH `after` and `requires`. `requires` alone pulls
          the import in but does not order against it; `after` alone orders but
          lets the barrier run in a transaction where the import was never
          queued. Both are needed.
        '';
      };

      attempts = mkOption {
        type = types.ints.positive;
        default = 7;
        description = ''
          Poll attempts with exponential backoff (1s, 2s, 4s, ...). 7 attempts
          is 127s of total sleep, which covers a slow spinning-disk pool import
          without letting a genuinely broken pool hang the boot forever.
        '';
      };

      wantedBy = mkOption {
        type = types.listOf types.str;
        default = [ "multi-user.target" ];
        description = ''
          Where the barrier is pulled in from. Keep `multi-user.target` so the
          barrier runs even when no consumer happens to be enabled — otherwise
          the failure is invisible until something else breaks.
        '';
      };
    };
  };
in
{
  options.boot.mirroredEsp = {
    enable = mkEnableOption "a mirrored EFI system partition with a pinned systemd-boot recovery entry";

    primary = {
      mountPoint = mkOption {
        type = types.str;
        default = "/boot";
        description = ''
          Mount point of the ESP that systemd-boot actually installs into.
          Must equal `boot.loader.efi.efiSysMountPoint` (or
          `boot.loader.systemd-boot.xbootldrMountPoint` when that is set) —
          asserted below.
        '';
      };

      device = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/dev/disk/by-uuid/1234-ABCD";
        description = ''
          Device for the primary ESP, applied with `mkForce` so it wins over a
          disko-generated `fileSystems` entry. Use a filesystem UUID: the two
          ESPs are byte-identical replicas, so `by-label` and `by-partlabel`
          are ambiguous and `by-id`/`by-path` change when a disk is moved to
          another slot. `null` leaves whatever else declared the mount alone.
        '';
      };
    };

    mirror = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Mirror the primary ESP onto a second ESP after every bootloader install.";
      };

      mountPoint = mkOption {
        type = types.str;
        default = "/boot-mirror";
        description = ''
          Mount point of the second ESP. It is a passive replica: systemd-boot
          never writes here, the rsync at the end of the install does.
        '';
      };

      device = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/dev/disk/by-uuid/5678-EF01";
        description = "Device for the mirror ESP. See `primary.device`.";
      };
    };

    mountOptions = mkOption {
      type = types.listOf types.str;
      default = [ "umask=0077" ];
      description = ''
        Mount options added to BOTH ESPs. `umask=0077` keeps the vfat tree
        root-only; without it a FAT ESP is world-readable and every unprivileged
        process can read the initrd, which on hosts using `boot.initrd.secrets`
        contains secrets.

        These are *added* to whatever else defines the mount (disko usually
        contributes `defaults`), because `fileSystems.<p>.options` is a
        `listOf` and concatenates definitions.
      '';
    };

    rsyncFlags = mkOption {
      type = types.listOf types.str;
      default = [
        "-a"
        "--delete"
      ];
      description = ''
        Flags for the mirroring rsync. `--delete` is the point: the mirror must
        be an exact replica, not a union of every generation that was ever
        installed, or it silently fills up and then diverges.
      '';
    };

    rsyncExcludes = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "loader/random-seed" ];
      description = ''
        Paths passed as `--exclude=`. See the README on
        `loader/random-seed`: `bootctl` treats it as per-installation state and
        explicitly says a cloned image must not carry someone else's seed.
      '';
    };

    recovery = {
      enable = mkEnableOption "restoring a pinned recovery kernel/initrd/entry onto the ESP after every install";

      directory = mkOption {
        type = types.str;
        default = "/var/lib/boot-recovery";
        example = "/persist/boot-recovery";
        description = ''
          Directory holding the pinned recovery payload. It must live OUTSIDE
          the Nix store and OUTSIDE the ESP:

          - outside the store, because `nix-collect-garbage` reaps the old
            generation's kernel and initrd;
          - outside the ESP, because systemd-boot's installer deletes every
            file under `<ESP>/EFI/nixos` that does not belong to one of the
            last `configurationLimit` generations.

          The install script is a no-op if the directory does not exist, so a
          host can be deployed before the payload is staged.
        '';
      };

      efiFiles = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [
          "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-linux-6.12.0-bzImage.efi"
          "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-initrd-linux-6.12.0-initrd.efi"
        ];
        description = ''
          Basenames inside `recovery.directory` copied back into
          `<ESP>/EFI/nixos/` on every install. Use the exact names the
          installer originally wrote, because the recovery `.conf` references
          them by path.
        '';
      };

      entryFiles = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "recovery-shell-init.conf" ];
        description = ''
          Basenames inside `recovery.directory` copied back into
          `<ESP>/loader/entries/`.

          A name matching `nixos-*.conf` is REJECTED by an assertion: the
          installer garbage-collects loader entries with exactly that regex,
          so such an entry would be deleted on the next deploy.
        '';
      };
    };

    coreutilsPackage = mkPackageOption pkgs "coreutils" { };
    rsyncPackage = mkPackageOption pkgs "rsync" { };
    utilLinuxPackage = mkPackageOption pkgs "util-linux" { };
  };

  options.boot.zfsMountBarriers = mkOption {
    type = types.attrsOf barrierType;
    default = { };
    example = lib.literalExpression ''
      {
        tank = {
          mountpoint = "/tank";
          importUnits = [ "zfs-import-tank.service" ];
        };
      }
    '';
    description = ''
      Oneshot units named `wait-for-zfs-<name>.service` that block until a ZFS
      mountpoint is really mounted. Consumers order themselves with
      `after`/`requires` on the barrier instead of racing an unmounted path.
    '';
  };

  config = mkMerge [
    (mkIf cfg.enable {
      assertions = [
        {
          assertion = sdb.enable;
          message = ''
            boot.mirroredEsp requires boot.loader.systemd-boot.enable — the
            recovery restore and the ESP mirror both run from
            boot.loader.systemd-boot.extraInstallCommands.
          '';
        }
        {
          assertion = !cfg.mirror.enable || cfg.mirror.mountPoint != cfg.primary.mountPoint;
          message = "boot.mirroredEsp.mirror.mountPoint must differ from boot.mirroredEsp.primary.mountPoint (rsync --delete onto itself).";
        }
        {
          assertion =
            if sdb.xbootldrMountPoint != null then
              cfg.primary.mountPoint == sdb.xbootldrMountPoint
            else
              cfg.primary.mountPoint == config.boot.loader.efi.efiSysMountPoint;
          message = ''
            boot.mirroredEsp.primary.mountPoint (${cfg.primary.mountPoint}) must be
            the partition systemd-boot writes entries and kernels to. With
            boot.loader.systemd-boot.xbootldrMountPoint set that is the XBOOTLDR
            mount, otherwise it is boot.loader.efi.efiSysMountPoint.
          '';
        }
        {
          assertion = badEntryNames == [ ];
          message = ''
            boot.mirroredEsp.recovery.entryFiles must not match nixos-*.conf
            (offending: ${concatStringsSep ", " badEntryNames}).
            systemd-boot-builder.py's garbage_collect() deletes every
            loader/entries file matching the regex `nixos-.+\.conf` that is not
            owned by a live generation, so such a recovery entry disappears on
            the next deploy. Rename it, e.g. recovery-shell-init.conf.
          '';
        }
        {
          assertion =
            !cfg.recovery.enable || !(lib.hasPrefix (cfg.primary.mountPoint + "/") cfg.recovery.directory);
          message = ''
            boot.mirroredEsp.recovery.directory (${cfg.recovery.directory}) is inside
            the ESP. The installer garbage-collects <ESP>/EFI/nixos, so a payload
            stored there is not pinned — it is exactly the thing being protected
            against. Stage it on persistent non-ESP storage.
          '';
        }
      ];

      warnings =
        lib.optional
          (cfg.recovery.enable && cfg.recovery.efiFiles == [ ] && cfg.recovery.entryFiles == [ ])
          "boot.mirroredEsp.recovery.enable is on but both efiFiles and entryFiles are empty; nothing is pinned.";

      boot.loader.systemd-boot.extraInstallCommands = installScript;

      fileSystems = mkMerge [
        (mkIf (cfg.primary.device != null) {
          ${cfg.primary.mountPoint}.device = mkForce cfg.primary.device;
        })
        (mkIf (cfg.mirror.enable && cfg.mirror.device != null) {
          ${cfg.mirror.mountPoint}.device = mkForce cfg.mirror.device;
        })
        (mkIf (cfg.mountOptions != [ ]) {
          ${cfg.primary.mountPoint}.options = cfg.mountOptions;
        })
        (mkIf (cfg.mirror.enable && cfg.mountOptions != [ ]) {
          ${cfg.mirror.mountPoint}.options = cfg.mountOptions;
        })
      ];
    })

    {
      systemd.services = lib.mapAttrs' (
        name: barrier: lib.nameValuePair "wait-for-zfs-${name}" (barrierUnit barrier)
      ) config.boot.zfsMountBarriers;
    }
  ];
}
