{
  config,
  lib,
  utils,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.zfsWipeOnBoot;

  # The initrd mount unit for a filesystem is the /sysroot-prefixed, systemd-
  # escaped mount point. This mirrors `getPoolMounts` in
  # nixos/modules/tasks/filesystems/zfs.nix, including the trailing-slash strip
  # that keeps "/" from becoming "sysroot-.mount".
  initrdMountUnit =
    mountPoint: "${utils.escapeSystemdPath ("/sysroot" + (lib.removeSuffix "/" mountPoint))}.mount";

  poolOf = dataset: lib.head (lib.splitString "/" dataset);

  enabled = lib.filterAttrs (_: e: e.enable) cfg.datasets;

  # sysroot.mount is the ONLY anchor that is always present and always ordered
  # ahead of every other /sysroot/* mount (systemd.mount(5): a mount unit
  # beneath another in the hierarchy gains an implicit Requires= and After= on
  # the parent). Naming the dataset's own mount unit as well is redundant but
  # self-documenting, and it costs nothing.
  beforeUnits =
    e:
    lib.unique (
      [ "sysroot.mount" ] ++ lib.optional (e.mountPoint != null) (initrdMountUnit e.mountPoint)
    );

  mkScript = e: ''
    snap="${e.dataset}@${e.snapshot}"
    if ! zfs list -H -t snapshot -o name "$snap" > /dev/null 2>&1; then
      ${
        {
          fail = ''
            echo "zfs-wipe-on-boot: $snap does not exist. Refusing to boot with" >&2
            echo "state that was supposed to be discarded. Create it with:" >&2
            echo "  zfs snapshot $snap" >&2
            exit 1
          '';
          create = ''
            echo "zfs-wipe-on-boot: $snap missing, creating it from the CURRENT" >&2
            echo "contents of ${e.dataset}. This boot keeps its state." >&2
            zfs snapshot "$snap"
          '';
          ignore = ''
            echo "zfs-wipe-on-boot: $snap missing, skipping rollback" >&2
            exit 0
          '';
        }
        .${e.onMissingSnapshot}
      }
    fi
    zfs rollback ${lib.optionalString e.recursive "-r "}"$snap"
  '';

  mkService = e: {
    description = "Wipe ${e.dataset} by rolling back to @${e.snapshot}";
    wantedBy = [ "initrd.target" ];
    after = [ "zfs-import-${poolOf e.dataset}.service" ] ++ e.after;
    requires = e.requires;
    before = beforeUnits e;
    unitConfig = {
      DefaultDependencies = "no";
    }
    // lib.optionalAttrs e.failHard {
      OnFailure = "emergency.target";
      OnFailureJobMode = "replace-irreversibly";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ cfg.package ];
    script = mkScript e;
  };

  mounted = lib.filterAttrs (_: e: e.mountPoint != null) enabled;

  # Which declared filesystem actually governs `path`? The DEEPEST matching
  # mount point wins, so a persisted dataset nested under a wiped one (the
  # usual /persist-under-/ layout) is correctly seen as safe.
  governingMount =
    path:
    let
      candidates = lib.filter (
        mp: mp == "/" || mp == path || lib.hasPrefix (mp + "/") path
      ) (lib.attrNames config.fileSystems);
    in
    lib.foldl' (a: b: if lib.stringLength b > lib.stringLength a then b else a) "/" candidates;

  wipedMountPoints = lib.mapAttrsToList (_: e: e.mountPoint) mounted;

  # A path is destroyed on every boot iff the mount governing it is wiped.
  onWipedPath = path: lib.elem (governingMount path) wipedMountPoints;

  # Only reason about real filesystem paths. Store paths are immutable and
  # irrelevant here; a non-absolute value is not ours to interpret.
  plainPath = p: let s = toString p; in lib.hasPrefix "/" s && !(lib.hasPrefix "/nix/store/" s);

  atRisk = paths: lib.filter (p: plainPath p && onWipedPath (toString p)) paths;

  sshdHostKeyPaths = lib.optionals (config.services.openssh.enable or false) (
    map (k: k.path) (config.services.openssh.hostKeys or [ ])
  );
  initrdHostKeyPaths = lib.optionals (config.boot.initrd.network.ssh.enable or false) (
    config.boot.initrd.network.ssh.hostKeys or [ ]
  );

  fsOf = e: config.fileSystems.${e.mountPoint} or null;

  datasetModule =
    { ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to wipe this dataset on every boot.";
        };

        dataset = mkOption {
          type = types.str;
          example = "rpool/local/home";
          # No default: guessing a dataset name from an attribute key is how a
          # wipe ends up pointed at nothing.
          description = ''
            Full ZFS dataset name. The pool component is used to derive the
            initrd import unit this rollback is ordered after
            (`zfs-import-<pool>.service`).
          '';
        };

        snapshot = mkOption {
          type = types.str;
          default = cfg.snapshot;
          defaultText = lib.literalExpression "config.zfsWipeOnBoot.snapshot";
          description = ''
            Snapshot name (without the `@`) representing the empty, known-good
            state. It must already exist before the first boot — create it at
            install time, e.g. from a disko `postCreateHook`.
          '';
        };

        mountPoint = mkOption {
          type = types.nullOr types.path;
          default = null;
          example = "/home";
          description = ''
            Where this dataset is mounted. Setting it turns on the
            `neededForBoot` guard rail (see `enforceNeededForBoot`) and the
            matching assertions. `null` means the dataset is not one of this
            host's `fileSystems`, in which case the only ordering anchor is
            `sysroot.mount`.
          '';
        };

        recursive = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Pass `-r` to `zfs rollback`, destroying any snapshot and bookmark
            newer than the target. Required for an unattended wipe: without it
            the rollback FAILS the moment anything (an auto-snapshot timer, a
            replication job) has taken a newer snapshot.

            The flip side: on a dataset with `com.sun:auto-snapshot=true` this
            silently destroys every automatic snapshot of that dataset on every
            boot. Do not enable auto-snapshots on a wiped dataset.
          '';
        };

        onMissingSnapshot = mkOption {
          type = types.enum [
            "fail"
            "create"
            "ignore"
          ];
          default = "fail";
          description = ''
            What to do when the blank snapshot does not exist.

            - `fail` — abort. Combined with `failHard` this stops the boot
              instead of silently keeping state.
            - `create` — snapshot the dataset's *current* contents under that
              name and continue. Convenient when adding a dataset to an
              existing host; this boot keeps whatever was there.
            - `ignore` — skip the rollback and continue. Only ever correct for
              a dataset you are in the middle of decommissioning.
          '';
        };

        failHard = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Add `OnFailure=emergency.target` /
            `OnFailureJobMode=replace-irreversibly` so a failed wipe drops to
            the initrd emergency shell rather than booting with state that was
            supposed to be gone.

            Set to `false` on remote hosts that have neither
            `boot.initrd.systemd.emergencyAccess` nor initrd SSH: there, the
            emergency target is an unreachable brick.
          '';
        };

        after = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "systemd-cryptsetup@crypted.service" ];
          description = ''
            Extra `After=` units. The pool's initrd import unit is added
            automatically; this is for anything the import itself depends on
            that is not already wired, such as a LUKS container.
          '';
        };

        requires = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Extra `Requires=` units.";
        };
      };
    };
in
{
  options.zfsWipeOnBoot = {
    enable = mkEnableOption "wiping ZFS datasets to a blank snapshot in the initrd";

    package = mkOption {
      type = types.package;
      default = config.boot.zfs.package;
      defaultText = lib.literalExpression "config.boot.zfs.package";
      description = ''
        ZFS package providing `zfs`. Must be the same build the initrd imports
        the pool with, or the rollback can hit a feature-flag mismatch.
      '';
    };

    snapshot = mkOption {
      type = types.str;
      default = "blank";
      description = "Default snapshot name for every entry in `datasets`.";
    };

    namePrefix = mkOption {
      type = types.str;
      default = "zfs-wipe";
      description = ''
        Prefix for the generated initrd unit names: `<prefix>-<key>.service`.
      '';
    };

    enforceNeededForBoot = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Set `fileSystems.<mountPoint>.neededForBoot = true` for every wiped
        dataset that names a mount point.

        This is not a convenience. `neededForBoot` is what puts the filesystem
        into the initrd fstab, and therefore what makes its
        `sysroot-*.mount` unit exist at all. Without it the mount happens in
        stage 2, long after the initrd has been torn down, and the wipe races
        against nothing that systemd can order it against.
      '';
    };

    datasets = mkOption {
      type = types.attrsOf (types.submodule datasetModule);
      default = { };
      example = lib.literalExpression ''
        {
          root = { dataset = "rpool/local/root"; mountPoint = "/"; };
          home = { dataset = "rpool/local/home"; mountPoint = "/home"; };
        }
      '';
      description = ''
        Datasets to roll back to their blank snapshot on every boot. The
        attribute name is used for the unit name and, unless overridden, as
        the dataset name.
      '';
    };
  };

  config = mkIf (cfg.enable && enabled != { }) {
    assertions = [
      {
        assertion = config.boot.initrd.systemd.enable;
        message = ''
          zfsWipeOnBoot requires the systemd initrd
          (`boot.initrd.systemd.enable = true`). Scripted stage 1 has no unit
          ordering at all: `boot.initrd.postDeviceCommands` runs as an
          unordered blob and is a removed option under systemd stage 1
          (nixos/modules/system/boot/systemd/initrd.nix, the `obsoleteOpt`
          list).
        '';
      }
    ]
    ++ lib.mapAttrsToList (name: e: {
      assertion = fsOf e != null;
      message = ''
        zfsWipeOnBoot.datasets.${name}.mountPoint is "${toString e.mountPoint}"
        but there is no `fileSystems."${toString e.mountPoint}"`. Either declare
        the filesystem or set mountPoint = null.
      '';
    }) mounted
    ++ lib.mapAttrsToList (name: e: {
      assertion = fsOf e == null || utils.fsNeededForBoot (fsOf e);
      message = ''
        zfsWipeOnBoot.datasets.${name} wipes ${e.dataset} mounted at
        ${toString e.mountPoint}, but that filesystem is not neededForBoot.

        Its `${initrdMountUnit e.mountPoint}` unit therefore does not exist in
        the initrd, the mount happens in stage 2 instead, and the wipe is
        unordered with respect to it. Set `neededForBoot = true` (or leave
        zfsWipeOnBoot.enforceNeededForBoot at its default).
      '';
    }) mounted
    ++ [
      {
        assertion = atRisk sshdHostKeyPaths == [ ];
        message = ''
          zfsWipeOnBoot would destroy this host's SSH host key on every boot:
          ${lib.concatStringsSep ", " (map toString (atRisk sshdHostKeyPaths))}

          services.openssh.hostKeys must live on a dataset that is NOT rolled
          back, or every reboot regenerates the machine's identity. sshd still
          starts, so nothing looks broken -- but every client that pinned the
          old key refuses to connect, and you find out from the one machine you
          can no longer reach.
        '';
      }
      {
        assertion = atRisk initrdHostKeyPaths == [ ];
        message = ''
          zfsWipeOnBoot would destroy the INITRD SSH host key:
          ${lib.concatStringsSep ", " (map toString (atRisk initrdHostKeyPaths))}

          boot.initrd.network.ssh.hostKeys is read from the live filesystem when
          the initrd secrets are assembled, so a wiped path loses it. On a
          remote-unlock host this is the worst version of the failure: the key
          that changed is the one used by whoever has to log in to unlock the
          disk, and there is no other way in.
        '';
      }
    ]
    ++ lib.mapAttrsToList (name: e: {
      assertion = fsOf e == null || (fsOf e).fsType == "zfs";
      message = ''
        zfsWipeOnBoot.datasets.${name} wipes the ZFS dataset ${e.dataset}, but
        fileSystems."${toString e.mountPoint}".fsType is
        "${(fsOf e).fsType}". Rolling a dataset back underneath a mount of a
        different filesystem does nothing useful.
      '';
    }) mounted;

    warnings = lib.filter (w: w != null) (
      lib.mapAttrsToList (
        name: e:
        if fsOf e != null && (fsOf e).device != null && (fsOf e).device != e.dataset then
          ''
            zfsWipeOnBoot.datasets.${name} rolls back "${e.dataset}" but
            fileSystems."${toString e.mountPoint}".device is
            "${(fsOf e).device}". If those are not the same dataset, the wipe
            is happening somewhere nobody is looking.
          ''
        else
          null
      ) mounted
    );

    fileSystems = mkIf cfg.enforceNeededForBoot (
      lib.mapAttrs' (_: e: lib.nameValuePair e.mountPoint { neededForBoot = true; }) mounted
    );

    boot.initrd.systemd.services = lib.mapAttrs' (
      name: e: lib.nameValuePair "${cfg.namePrefix}-${name}" (mkService e)
    ) enabled;
  };
}
