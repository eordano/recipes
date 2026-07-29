# zfs-native-encryption-keys — load ZFS *native* encryption keys for non-root
# pools from a runtime secret, ordered so nothing touches the mountpoints
# before the datasets are actually mounted.
#
# ZFS native encryption is per-dataset (per "encryption root"), not per block
# device, so unlocking is `zfs load-key`, not `cryptsetup open`. nixpkgs only
# ever loads keys as a side effect of importing a pool, from whatever
# `keylocation` the dataset carries on disk. That is fine for a root pool
# answered by a boot prompt, and wrong for a data pool whose key comes from a
# secret manager: you want the key path to live in the NixOS config, not
# baked into an on-disk property, you want a missing key to FAIL rather than
# hang on a console prompt nobody is watching, and you want consumers ordered
# after the datasets are mounted.
#
# `zfs load-key -L <location>` overrides the stored `keylocation` for that one
# call without rewriting the property, which is what makes it possible to keep
# `keylocation=prompt` on disk (nothing on the disk points at the key) and
# still unlock from a runtime file.
#
# See README.md for the traps, including the `grep -q available` substring bug
# that silently turns a hand-rolled version of this unit into a no-op.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.zfsNativeKeys;

  credentialName = "zfs-key";

  poolOpts =
    { name, ... }:
    {
      options = {
        datasets = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ name ];
          defaultText = lib.literalExpression ''[ "<pool name>" ]'';
          example = [
            "tank/archive"
            "tank/media"
          ];
          description = ''
            Encryption roots to unlock, in order. These must be encryption
            ROOTS — `zfs load-key` on an inheriting child fails with
            "Keys must be loaded for encryption root". Check with
            `zfs get -r encryptionroot <pool>`.

            A pool created with `zpool create -O encryption=...` has exactly one
            encryption root (the pool itself), no matter how many disks the vdev
            has; list just the pool name in that case.
          '';
        };

        keyFile = lib.mkOption {
          type = lib.types.str;
          example = "/run/secrets/tank.key";
          description = ''
            Path to the raw key / passphrase, as it exists at RUNTIME on the
            host. Deliberately a string, not a `path`: a `path` would copy the
            key into the world-readable Nix store. Point this at a secret
            manager's output (agenix, sops-nix, systemd-creds, a ramfs file).

            The contents must match the dataset's `keyformat` — for
            `keyformat=passphrase` that is 8..512 characters with no trailing
            newline.
          '';
        };

        useCredential = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Hand the key to the unit through systemd's `LoadCredential=`
            instead of letting `zfs` read {option}`keyFile` directly.

            Two things come for free: systemd reads the source as root at unit
            start and exposes it 0400 in a per-unit tmpfs, and a missing or
            unreadable source makes systemd refuse to start the unit — a
            fail-closed check you do not have to write.

            Turn this off only if the key source is not readable at unit start
            (e.g. it appears on a filesystem this unit itself must unlock).
          '';
        };

        preflight = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            When {option}`useCredential` is off, test the key file for
            readability first and exit with a clear message instead of letting
            `zfs load-key` fail with "Key load error: Failed to open key
            material file".

            Do NOT replace this with `unitConfig.ConditionPathExists` on the key
            file: a failed Condition marks the unit *successfully skipped*, so
            the boot proceeds with the datasets locked and consumers write into
            the bare mountpoint. That is fail-OPEN. This check is fail-closed.
          '';
        };

        unitName = lib.mkOption {
          type = lib.types.str;
          default = "zfs-load-key-${name}";
          defaultText = lib.literalExpression ''"zfs-load-key-<pool name>"'';
          description = "Name of the generated systemd unit (without `.service`).";
        };

        description = lib.mkOption {
          type = lib.types.str;
          default = "Load encryption key for ${name} ZFS pool";
          defaultText = lib.literalExpression ''"Load encryption key for <pool name> ZFS pool"'';
          description = "systemd unit description.";
        };

        wantedBy = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "multi-user.target" ];
          description = "Targets that pull the key-load unit in at boot.";
        };

        after = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "zfs-import-${name}.service" ];
          defaultText = lib.literalExpression ''[ "zfs-import-<pool name>.service" ]'';
          description = ''
            Units this must run after. The default is nixpkgs' generated import
            unit for the pool — a key cannot be loaded into a pool that is not
            imported yet. If the key itself lives on another encrypted pool, add
            that pool's key-load unit here too.
          '';
        };

        before = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "nginx.service" ];
          description = ''
            Units ordered after the key is loaded. Ordering ONLY: these still
            start if the key never loads. Use {option}`requiredBy` for consumers
            that must not run at all against locked datasets.
          '';
        };

        requiredBy = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "nginx.service" ];
          description = ''
            Units that hard-depend on the key being loaded: they get
            `Requires=` on this unit and are ordered after it, so a failed key
            load stops them from starting instead of letting them write into an
            empty mountpoint.
          '';
        };

        mounts = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          example = {
            "/tank/media" = "tank/media";
          };
          description = ''
            Mountpoint -> dataset. Generates `fileSystems` entries with
            `zfsutil` plus `x-systemd.requires=` / `x-systemd.after=` on the
            key-load unit, so the mount cannot be attempted while the dataset is
            still locked. Anything that declares `RequiresMountsFor=` on one of
            these paths then inherits the whole chain.
          '';
        };

        mountOptions = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "zfsutil"
            "noauto"
            "x-systemd.wanted-by=multi-user.target"
          ];
          example = [
            "zfsutil"
            "noauto"
            "x-systemd.wanted-by=multi-user.target"
          ];
          description = ''
            Base mount options for the generated {option}`mounts` entries; the
            `x-systemd.requires=` / `x-systemd.after=` ordering options are
            appended.

            The default deliberately keeps these mounts OUT of
            `local-fs.target`, and that is load-bearing. An ordinary
            `systemd.services` unit carries `DefaultDependencies=yes`, hence
            `After=basic.target`, and `basic.target` is ordered after
            `sysinit.target` after `local-fs.target`. Wire a *local-fs* mount to
            `x-systemd.requires=` this unit and you close a loop:

                local-fs.target -> <your>.mount -> zfs-load-key-<pool>.service
                  -> basic.target -> sysinit.target -> local-fs.target

            systemd does not refuse to boot on that. It breaks the loop by
            DELETING jobs — in practice `local-fs.target` itself, plus whatever
            else it picks — logs `Found ordering cycle` to the journal, and
            carries on looking healthy. `noauto` drops the
            `Before=local-fs.target` edge and `x-systemd.wanted-by=` puts the
            mount back on the boot path late, where it cannot cycle.

            Do NOT "fix" the cycle by setting `DefaultDependencies=no` on the
            key-load unit instead: that pulls it in front of everything that
            produces the key at runtime, which is the failure in the table at
            the top of the README.
          '';
        };

        mountAll = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Run `zfs mount -a` at the end of the unit, for pools whose datasets
            use ZFS-managed (non-`legacy`) mountpoints and are therefore not
            declared in {option}`mounts`. Prefer {option}`mounts`: declared
            mount units are what lets other units order against them.
          '';
        };
      };
    };

  zfsBin = "${cfg.package}/sbin/zfs";

  keyUrl =
    pool:
    if pool.useCredential then
      ''"file://$CREDENTIALS_DIRECTORY/${credentialName}"''
    else
      ''"file://${pool.keyFile}"'';

  poolScript = pool: ''
    ${lib.optionalString (!pool.useCredential && pool.preflight) ''
      if [ ! -r ${lib.escapeShellArg pool.keyFile} ]; then
        echo "key file ${pool.keyFile} is missing or unreadable; refusing to continue with locked datasets" >&2
        exit 1
      fi
    ''}
    for dataset in ${lib.escapeShellArgs pool.datasets}; do
      status=$(${zfsBin} get -H -o value keystatus "$dataset" || true)
      case "$status" in
        available)
          echo "key already loaded for $dataset"
          continue
          ;;
        unavailable)
          echo "loading key for $dataset"
          ${zfsBin} load-key -L ${keyUrl pool} "$dataset"
          ;;
        *)
          echo "$dataset: unexpected keystatus '$status' (not an encryption root, or dataset missing)" >&2
          exit 1
          ;;
      esac
    done
    ${lib.optionalString pool.mountAll "${zfsBin} mount -a"}
  '';

  unitFor = pool: {
    name = pool.unitName;
    value = {
      inherit (pool) description wantedBy after;
      before = lib.unique (pool.before ++ pool.requiredBy);
      requiredBy = pool.requiredBy;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      }
      // lib.optionalAttrs pool.useCredential {
        LoadCredential = "${credentialName}:${pool.keyFile}";
      };
      script = poolScript pool;
    };
  };

  mountsFor =
    pool:
    lib.mapAttrs (_mountpoint: dataset: {
      device = dataset;
      fsType = "zfs";
      options = pool.mountOptions ++ [
        "x-systemd.requires=${pool.unitName}.service"
        "x-systemd.after=${pool.unitName}.service"
      ];
    }) pool.mounts;

  pools = lib.attrValues cfg.pools;
in
{
  options.services.zfsNativeKeys = {
    enable = lib.mkEnableOption "loading ZFS native encryption keys for non-root pools from a runtime key file";

    package = lib.mkOption {
      type = lib.types.package;
      default = config.boot.zfs.package;
      defaultText = lib.literalExpression "config.boot.zfs.package";
      description = ''
        ZFS userland used by the generated units. Defaults to the same build
        the rest of the system uses, so the CLI can never drift away from the
        loaded kernel module across an upgrade.
      '';
    };

    disableZfsMountService = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Disable nixpkgs' `zfs-mount.service` (`zfs mount -a`).

        Set this when every dataset you care about is declared in
        {option}`mounts` (i.e. `mountpoint=legacy`): the blanket `zfs mount -a`
        then has nothing legitimate to do, but still runs early enough to race
        the declared mount units and fails outright on any dataset whose key is
        not loaded yet. Leave it alone if other datasets on the host rely on
        ZFS-managed mountpoints.
      '';
    };

    restrictImportCredentialsTo = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      example = [ "rpool" ];
      description = ''
        Convenience for pinning {option}`boot.zfs.requestEncryptionCredentials`
        to a specific dataset list, so nixpkgs' import units stop trying to
        unlock the pools this module manages.

        It defaults to `true` upstream, which means "ask for every encrypted
        dataset at import" — for a dataset carrying `keylocation=prompt` that is
        a `systemd-ask-password` with `boot.zfs.passwordTimeout` (default 0 =
        wait forever) in front of the pool's mount units. Set this to just the
        root pool's datasets and let this module handle the rest.

        `null` (default) leaves the option untouched.
      '';
    };

    pools = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule poolOpts);
      default = { };
      description = ''
        Pools to unlock, keyed by POOL NAME (the attribute name is used to
        derive the default import unit to order after, and the default dataset
        list).
      '';
      example = lib.literalExpression ''
        {
          tank = {
            datasets = [ "tank/archive" "tank/media" ];
            keyFile = "/run/secrets/tank.key";
            mounts = {
              "/tank/archive" = "tank/archive";
              "/tank/media" = "tank/media";
            };
            requiredBy = [ "nginx.service" ];
          };
        }
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.pools != { }) {
    assertions =
      lib.mapAttrsToList (poolName: pool: {
        assertion = lib.all (ds: ds == poolName || lib.hasPrefix "${poolName}/" ds) pool.datasets;
        message = ''
          services.zfsNativeKeys.pools.${poolName}: every dataset must belong to
          pool "${poolName}" (the attribute name IS the pool name, and is what
          the default `after = [ "zfs-import-${poolName}.service" ]` is built
          from). Got: ${lib.concatStringsSep ", " pool.datasets}
        '';
      }) cfg.pools
      ++ lib.mapAttrsToList (poolName: pool: {
        assertion = pool.keyFile != "";
        message = "services.zfsNativeKeys.pools.${poolName}.keyFile must be set to a runtime path holding the key.";
      }) cfg.pools;

    systemd.services = lib.mkMerge [
      (lib.listToAttrs (map unitFor pools))
      (lib.mkIf cfg.disableZfsMountService { zfs-mount.enable = false; })
    ];

    fileSystems = lib.mkMerge (map mountsFor pools);

    boot.zfs.requestEncryptionCredentials = lib.mkIf (
      cfg.restrictImportCredentialsTo != null
    ) cfg.restrictImportCredentialsTo;
  };
}
