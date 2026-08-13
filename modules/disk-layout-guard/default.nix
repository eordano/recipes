{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.diskLayoutGuard;
  inherit (lib) mkOption types mkIf;

  optional' = fs: lib.elem "nofail" fs.options || lib.elem "noauto" fs.options;

  mounts = lib.filter (fs: !(optional' fs)) (lib.attrValues config.fileSystems);

  declaredBlockDevices = lib.subtractLists cfg.ignoreDevices (
    lib.unique (
      map (fs: fs.device) (lib.filter (fs: fs.device != null && lib.hasPrefix "/dev/" fs.device) mounts)
      ++ map (d: d.device) (lib.attrValues config.boot.initrd.luks.devices)
    )
  );

  declaredZfsPools = lib.unique (
    map (fs: lib.head (lib.splitString "/" fs.device)) (
      lib.filter (fs: fs.fsType == "zfs" && fs.device != null) mounts
    )
  );

  luksCount = lib.length (lib.attrNames config.boot.initrd.luks.devices);

  zpoolBin = "${config.boot.zfs.package}/sbin/zpool";
  mktempBin = "${pkgs.coreutils}/bin/mktemp";
  rmBin = "${pkgs.coreutils}/bin/rm";

  checkDevices = lib.optionalString (declaredBlockDevices != [ ]) ''
    devices=(${lib.escapeShellArgs declaredBlockDevices})
    for dev in "''${devices[@]}"; do
      if [ ! -e "$dev" ]; then
        missing="$missing $dev"
      fi
    done
  '';

  checkPools = lib.optionalString (declaredZfsPools != [ ]) ''
    pools=(${lib.escapeShellArgs declaredZfsPools})
    for pool in "''${pools[@]}"; do
      if ! ${zpoolBin} list "$pool" > /dev/null 2>&1; then
        missing="$missing zpool:$pool"
      fi
    done
  '';

  checkEncryptionLayer = lib.optionalString (declaredZfsPools != [ ] && luksCount == 0) ''
    : > "$tmp/crypt-vdevs"
    cryptPools=(${lib.escapeShellArgs declaredZfsPools})
    for pool in "''${cryptPools[@]}"; do
      # Capture zpool's own exit status (a pipe would mask it behind `while`).
      if ! ${zpoolBin} list -vHP "$pool" > "$tmp/vdev-list" 2> /dev/null; then
        echo "disk-layout-guard: could not query the vdevs of ZFS pool '$pool'" >&2
        echo "(zpool is unavailable or exited non-zero), so this check cannot tell" >&2
        echo "whether the pool is backed by dm-crypt." >&2
        echo "" >&2
        echo "Treating dm-crypt detection as INCONCLUSIVE, not clean: if you are" >&2
        echo "dropping boot.initrd.luks.devices, verify by hand that the incoming" >&2
        echo "generation can still unlock this pool at the next boot." >&2
        continue
      fi
      while read -r vdev _rest; do
        case "$vdev" in
          */dm-uuid-CRYPT-* | */dm-name-* | /dev/mapper/*)
            echo crypt
            ;;
        esac
      done < "$tmp/vdev-list" >> "$tmp/crypt-vdevs"
    done
    if [ -s "$tmp/crypt-vdevs" ]; then
      echo "disk-layout-guard: the running root pool is backed by dm-crypt devices, but this" >&2
      echo "configuration declares no boot.initrd.luks.devices at all." >&2
      echo "" >&2
      echo "Activating it would install a generation whose initrd cannot unlock the disks;" >&2
      echo "the running system keeps working, so the breakage only appears at the next boot." >&2
      echo "Either restore the LUKS declarations, or re-provision the disks to match." >&2
      fatal=1
    fi
  '';
in
{
  options.modules.diskLayoutGuard = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Refuse to activate a generation whose boot-critical storage does not
        exist on this host.
      '';
    };

    ignoreDevices = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "/dev/disk/by-partlabel/scratch" ];
      description = "Device paths exempted from the existence check.";
    };
  };

  config = mkIf (cfg.enable && (declaredBlockDevices != [ ] || declaredZfsPools != [ ])) {
    system.preSwitchChecks.diskLayout = ''
      missing=""
      fatal=0
      tmp=$(${mktempBin} -d)
      trap '${rmBin} -rf "$tmp"' EXIT

      ${checkDevices}
      ${checkPools}
      ${checkEncryptionLayer}

      if [ -n "$missing" ]; then
        echo "disk-layout-guard: this configuration declares storage that does not exist here:" >&2
        for item in $missing; do
          echo "  $item" >&2
        done
        echo "" >&2
        echo "switch-to-configuration installs the bootloader before it restarts mounts, so" >&2
        echo "continuing would write a generation that cannot find its own root or ESP. The" >&2
        echo "running system would survive; the next boot would not." >&2
        echo "" >&2
        echo "Fix the declaration to match the disks, or re-provision the disks to match it." >&2
        fatal=1
      fi

      if [ "$fatal" -ne 0 ]; then
        exit 1
      fi
    '';
  };
}
