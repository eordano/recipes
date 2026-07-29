# NixOS VM test for the zfs-native-encryption-keys module.
#
# Run it standalone (no flake needed):
#
#   nix-build test.nix --arg pkgs 'import <nixpkgs> { system = "x86_64-linux"; }'
#
# or from a flake:
#
#   pkgs.callPackage ./modules/zfs-native-encryption-keys/test.nix { }
#
# What it proves:
#
#   0. (eval-time) `mounts` generates the exact `fileSystems` entry — device,
#      fsType and the `x-systemd.*` ordering options — wired to the key unit.
#      The generated value is then fed to the VM through
#      `virtualisation.fileSystems`, because `qemu-vm.nix` replaces `fileSystems`
#      wholesale with `mkVMOverride config.virtualisation.fileSystems`
#      (nixos/modules/virtualisation/qemu-vm.nix:1413) and a VM test would
#      otherwise never see a module's declared mounts at all. The mount unit the
#      VM builds from it is asserted on at runtime.
#   1. The unit UNLOCKS THE POOL ON THIS BOOT. The pool is exported and
#      re-imported with `-N` by the setup scaffolding, so the key is genuinely
#      unavailable when the unit runs: the test asserts the unit logged
#      "loading key for …" and did NOT take the "key already loaded" shortcut.
#      Without that, `zpool create` leaves the key loaded and every downstream
#      assertion passes against a module that does nothing.
#   2. The pool's ON-DISK `keylocation` is `prompt`, so the unlock can only have
#      come from `zfs load-key -L file://…` — and `-L` does not rewrite the
#      stored property afterwards.
#   3. Datasets are genuinely available: mounted, writable, readable back.
#   4. Locking is real. Mid-test the datasets are unmounted and the key
#      unloaded; the data becomes inaccessible and `zfs mount -a` cannot bring
#      it back. Restarting the unit alone restores it. This is the control that
#      makes "available" mean something.
#   5. Declared `mounts`: the generated `.mount` unit carries `Requires=` and
#      `After=` the key unit, and mounts the dataset once the key is loaded.
#   6. Consumers in `requiredBy` get `Requires=` + `After=`, and on the happy
#      path actually run.
#   7. `disableZfsMountService` masks `zfs-mount.service`; `mountAll` mounts the
#      ZFS-managed datasets.
#   8. It survives a reboot: pool comes back locked, unit unlocks it, data intact.
#   9. Fail CLOSED, on BOTH key-delivery paths, with the pools present and
#      imported so the failure is unambiguously about the key:
#        - `useCredential = true`  -> systemd refuses to start the unit
#          (243/CREDENTIALS).
#        - `useCredential = false` -> the `preflight` check exits non-zero.
#      In both cases the unit ends up `failed` with `ConditionResult=yes` (NOT
#      "successfully skipped", which is what an obvious-looking
#      `ConditionPathExists` fix would produce — that is fail-OPEN), the
#      datasets stay locked and unmounted, the declared mount refuses to mount,
#      the `requiredBy` consumers never run, and the machine still reaches
#      multi-user.target instead of hanging on a prompt nobody can answer.
{ pkgs, ... }:
let
  inherit (pkgs) lib;

  # Dogfoods lib/nixos-test-topology's `secretsStub` fixture: the key is
  # delivered at the real secret provider's path convention
  # (`config.age.secrets.<n>.path`), which is how this module is used in
  # practice. `mkTopology` itself is deliberately NOT used here — see README:
  # the nodes in this test never exchange a packet, so there is no address
  # assignment to take away from the framework.
  topology = import ../../lib/nixos-test-topology;

  passphrase = "test-encryption-passphrase";
  datasets = [
    "archive"
    "media"
  ];

  keyPath = "/run/agenix/testpool-key";
  missingCredKey = "/run/agenix/lockedcred-key-that-never-appears";
  missingPlainKey = "/run/agenix/lockedplain-key-that-never-appears";

  # --- 0. eval-time capture of the generated `fileSystems` wiring -------------
  #
  # A plain (non-VM) evaluation of the module, used both to assert the wiring
  # and to hand the module's OWN generated mount definition to the VM nodes.
  evalPool =
    poolName: poolCfg:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        ./default.nix
        {
          boot.loader.grub.enable = false;
          system.stateVersion = "25.05";
          networking.hostId = "00000000";
          fileSystems."/" = {
            device = "/dev/vda";
            fsType = "ext4";
          };
          services.zfsNativeKeys = {
            enable = true;
            pools.${poolName} = poolCfg;
          };
        }
      ];
    }).config;

  # Exactly the attributes `mountsFor` sets, taken from a real evaluation of the
  # module rather than re-typed by hand.
  generatedMounts =
    poolName: poolCfg:
    lib.mapAttrs (_: fs: { inherit (fs) device fsType options; }) (
      lib.getAttrs (lib.attrNames poolCfg.mounts) (evalPool poolName poolCfg).fileSystems
    );

  serverPool = {
    keyFile = keyPath;
    after = [ "testpool-setup.service" ];
    requiredBy = [ "zfs-consumer.service" ];
    mountAll = true;
    mounts."/mnt/legacy" = "testpool/legacy";
    mountOptions = [
      "zfsutil"
      "noauto"
    ];
  };

  lockedCredPool = {
    keyFile = missingCredKey;
    after = [ "lockedpools-setup.service" ];
    requiredBy = [ "cred-consumer.service" ];
    mounts."/mnt/locked" = "lockedcred/legacy";
    mountOptions = [
      "zfsutil"
      "noauto"
    ];
  };

  lockedPlainPool = {
    keyFile = missingPlainKey;
    useCredential = false;
    after = [ "lockedpools-setup.service" ];
    requiredBy = [ "plain-consumer.service" ];
    mountAll = true;
  };

  wiredMount = (evalPool "testpool" serverPool).fileSystems."/mnt/legacy";

  wiringOk =
    wiredMount.device == "testpool/legacy"
    && wiredMount.fsType == "zfs"
    &&
      wiredMount.options == [
        "zfsutil"
        "noauto"
        "x-systemd.requires=zfs-load-key-testpool.service"
        "x-systemd.after=zfs-load-key-testpool.service"
      ];

  # The pools above all pass `mountOptions` explicitly, so they say nothing
  # about what a user who takes the DEFAULT gets. That default is the one that
  # can deadlock: a local-fs mount requiring an ordinary service closes
  # local-fs.target -> mount -> service -> basic.target -> sysinit.target ->
  # local-fs.target, and systemd resolves it by deleting jobs rather than
  # failing, so every downstream assertion here would still pass.
  defaultWiredMount =
    (evalPool "defpool" {
      keyFile = keyPath;
      mounts."/mnt/default" = "defpool/legacy";
    }).fileSystems."/mnt/default";

  defaultIsCycleFree =
    lib.elem "noauto" defaultWiredMount.options
    && lib.any (lib.hasPrefix "x-systemd.wanted-by=") defaultWiredMount.options;

  markerUnit = name: {
    description = "Consumer that must not run against locked datasets";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = "touch /run/${name}-ran";
  };
in
assert lib.assertMsg defaultIsCycleFree ''
  services.zfsNativeKeys `mounts` generates a local-fs mount by default again.
  With no `mountOptions` override the entry must carry both `noauto` and an
  `x-systemd.wanted-by=`, or the generated mount and the generated key-load
  unit form an ordering cycle that systemd silently breaks by deleting
  local-fs.target. Got: ${lib.generators.toPretty { } defaultWiredMount.options}
'';
assert lib.assertMsg wiringOk ''
  services.zfsNativeKeys `mounts` no longer generates the expected fileSystems
  entry. Got: ${
    lib.generators.toPretty { } {
      inherit (wiredMount) device fsType options;
    }
  }
'';
pkgs.testers.runNixOSTest {
  name = "zfs-native-encryption-keys";

  nodes = {
    # Happy path: pool exists, key file present at the secret provider's path.
    server =
      { config, lib, ... }:
      {
        imports = [
          ./default.nix
          (topology.secretsStub {
            contents.testpool-key = passphrase;
            consumers = [
              "testpool-setup.service"
              "zfs-load-key-testpool.service"
            ];
          })
        ];

        age.secrets.testpool-key = { };

        boot.supportedFilesystems = [ "zfs" ];
        networking.hostId = "00000000";
        virtualisation.emptyDiskImages = [ 1024 ];
        virtualisation.memorySize = 2048;

        # The module's own generated mount definition, routed around
        # `qemu-vm.nix`'s wholesale `fileSystems` override.
        virtualisation.fileSystems = generatedMounts "testpool" serverPool;

        # Scaffolding only: stands in for "the pool already exists", which on a
        # real host is a one-off `zpool create` / disko run. It creates the pool
        # with a file keylocation, flips the property to `prompt` (the same
        # postCreateHook trick disko configs use, so the key path never survives
        # on disk), and then EXPORTS and re-imports with `-N` so the key is
        # genuinely unloaded by the time the module's unit runs.
        systemd.services.testpool-setup = {
          description = "Create or import the encrypted test pool";
          wantedBy = [ "multi-user.target" ];
          before = [ "zfs-load-key-testpool.service" ];
          path = [ config.boot.zfs.package ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            if zpool list testpool >/dev/null 2>&1; then
              exit 0
            fi
            if zpool import -N -f testpool >/dev/null 2>&1; then
              exit 0
            fi
            zpool create -f \
              -O encryption=aes-256-gcm \
              -O keyformat=passphrase \
              -O keylocation=file://${keyPath} \
              testpool /dev/vdb
            ${lib.concatMapStringsSep "\n" (d: "zfs create testpool/${d}") datasets}
            zfs create -o mountpoint=/mnt/legacy -o canmount=noauto testpool/legacy
            zfs set keylocation=prompt testpool
            zpool export testpool
            zpool import -N -f testpool
          '';
        };

        services.zfsNativeKeys = {
          enable = true;
          disableZfsMountService = true;
          restrictImportCredentialsTo = [ ];
          pools.testpool = serverPool;
        };

        systemd.services.zfs-consumer = markerUnit "zfs-consumer";
      };

    # Fail-closed path, both key-delivery mechanisms, with the pools present and
    # imported so a failure cannot be blamed on a missing pool.
    locked =
      { config, lib, ... }:
      {
        imports = [ ./default.nix ];

        boot.supportedFilesystems = [ "zfs" ];
        networking.hostId = "00000001";
        virtualisation.emptyDiskImages = [
          1024
          1024
        ];
        virtualisation.memorySize = 2048;

        virtualisation.fileSystems = generatedMounts "lockedcred" lockedCredPool;

        # Scaffolding key, at a path the module never looks at. The module's
        # keyFile points somewhere that will never exist.
        environment.etc."zfs-scaffolding-key" = {
          text = passphrase;
          mode = "0400";
        };

        systemd.services.lockedpools-setup = {
          description = "Create or import the encrypted test pools";
          wantedBy = [ "multi-user.target" ];
          before = [
            "zfs-load-key-lockedcred.service"
            "zfs-load-key-lockedplain.service"
          ];
          path = [ config.boot.zfs.package ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script =
            lib.concatMapStringsSep "\n"
              (p: ''
                if ! zpool list ${p.pool} >/dev/null 2>&1 \
                   && ! zpool import -N -f ${p.pool} >/dev/null 2>&1; then
                  zpool create -f \
                    -O encryption=aes-256-gcm \
                    -O keyformat=passphrase \
                    -O keylocation=file:///etc/zfs-scaffolding-key \
                    ${p.pool} ${p.disk}
                  zfs create ${p.childOpts} ${p.pool}/${p.child}
                  zfs set keylocation=prompt ${p.pool}
                  zpool export ${p.pool}
                  zpool import -N -f ${p.pool}
                fi
              '')
              [
                {
                  pool = "lockedcred";
                  disk = "/dev/vdb";
                  child = "legacy";
                  childOpts = "-o mountpoint=/mnt/locked -o canmount=noauto";
                }
                {
                  pool = "lockedplain";
                  disk = "/dev/vdc";
                  child = "data";
                  childOpts = "";
                }
              ];
        };

        services.zfsNativeKeys = {
          enable = true;
          restrictImportCredentialsTo = [ ];
          pools = {
            lockedcred = lockedCredPool;
            lockedplain = lockedPlainPool;
          };
        };

        systemd.services.cred-consumer = markerUnit "cred-consumer";
        systemd.services.plain-consumer = markerUnit "plain-consumer";
      };
  };

  testScript = ''
    start_all()

    with subtest("the unit unlocked the pool on THIS boot"):
        server.wait_for_unit("multi-user.target")
        server.wait_for_unit("zfs-load-key-testpool.service")
        # The scaffolding exported and re-imported with -N, so the key really
        # was unavailable. If it had not been, the unit would take the
        # "key already loaded" branch and prove nothing.
        server.succeed(
            "journalctl -b 0 -u zfs-load-key-testpool.service | grep -q 'loading key for testpool'"
        )
        server.fail(
            "journalctl -b 0 -u zfs-load-key-testpool.service | grep -q 'key already loaded'"
        )

    with subtest("unlocked from a runtime key file, with keylocation=prompt on disk"):
        server.succeed("zfs get -H -o value keystatus testpool | grep -qx available")
        server.succeed("zfs get -H -o value encryption testpool | grep -qx aes-256-gcm")
        # `-L` overrode the stored property without rewriting it: nothing on
        # disk points at the key.
        server.succeed("zfs get -H -o value keylocation testpool | grep -qx prompt")
        # And the key really came from the secret provider's path.
        server.succeed("test -f ${keyPath}")

    with subtest("mountAll mounted the ZFS-managed datasets and they are usable"):
        for d in ${builtins.toJSON datasets}:
            server.succeed(f"findmnt -no FSTYPE /testpool/{d} | grep -qx zfs")
            server.succeed(f"echo persisted > /testpool/{d}/marker")
            server.succeed(f"grep -qx persisted /testpool/{d}/marker")

    with subtest("declared mounts: the generated unit is ordered on the key unit"):
        server.succeed(
            "systemctl show -p Requires mnt-legacy.mount | grep -q zfs-load-key-testpool.service"
        )
        server.succeed(
            "systemctl show -p After mnt-legacy.mount | grep -q zfs-load-key-testpool.service"
        )
        server.succeed("systemctl start mnt-legacy.mount")
        server.succeed("findmnt -no SOURCE /mnt/legacy | grep -qx testpool/legacy")
        server.succeed("findmnt -no FSTYPE /mnt/legacy | grep -qx zfs")
        server.succeed("echo legacy-persisted > /mnt/legacy/marker")

    with subtest("requiredBy consumers are wired and did run"):
        server.succeed(
            "systemctl show -p After zfs-consumer.service | grep -q zfs-load-key-testpool.service"
        )
        server.succeed(
            "systemctl show -p Requires zfs-consumer.service | grep -q zfs-load-key-testpool.service"
        )
        server.succeed("test -f /run/zfs-consumer-ran")

    with subtest("disableZfsMountService keeps the blanket mount -a out of the way"):
        # `|| true` because `systemctl is-enabled` EXITS NON-ZERO for a masked
        # unit, and the test driver runs commands under `set -o pipefail`.
        server.succeed('test "$(systemctl is-enabled zfs-mount.service || true)" = masked')
        server.fail("systemctl is-active --quiet zfs-mount.service")

    with subtest("locking is real: without the key the data is inaccessible"):
        server.succeed("systemctl stop mnt-legacy.mount")
        server.succeed("zfs unmount -a")
        server.succeed("zfs unload-key -a")
        server.succeed("zfs get -H -o value keystatus testpool | grep -qx unavailable")
        server.succeed("zfs mount -a || true")
        server.fail("findmnt -no FSTYPE /testpool/archive")
        server.fail("test -e /testpool/archive/marker")
        server.fail("systemctl start mnt-legacy.mount")
        server.fail("findmnt -no FSTYPE /mnt/legacy")

    with subtest("restarting the unit alone brings the datasets back"):
        server.succeed("systemctl restart zfs-load-key-testpool.service")
        server.succeed("zfs get -H -o value keystatus testpool | grep -qx available")
        for d in ${builtins.toJSON datasets}:
            server.succeed(f"findmnt -no FSTYPE /testpool/{d} | grep -qx zfs")
            server.succeed(f"grep -qx persisted /testpool/{d}/marker")
        server.succeed("systemctl start mnt-legacy.mount")
        server.succeed("grep -qx legacy-persisted /mnt/legacy/marker")

    with subtest("survives a reboot: comes back locked, is unlocked again"):
        server.succeed("sync")
        server.shutdown()
        server.start()
        server.wait_for_unit("multi-user.target")
        server.wait_for_unit("zfs-load-key-testpool.service")
        server.succeed(
            "journalctl -b 0 -u zfs-load-key-testpool.service | grep -q 'loading key for testpool'"
        )
        server.succeed("zfs get -H -o value keystatus testpool | grep -qx available")
        server.succeed("zfs get -H -o value keylocation testpool | grep -qx prompt")
        for d in ${builtins.toJSON datasets}:
            server.succeed(f"findmnt -no FSTYPE /testpool/{d} | grep -qx zfs")
            server.succeed(f"grep -qx persisted /testpool/{d}/marker")

    # --- fail closed -------------------------------------------------------
    #
    # Both pools exist and are imported on this node; only the key files are
    # missing. So every assertion below is about the KEY, not about a pool that
    # was never there.
    with subtest("a missing key never blocks the boot on a prompt"):
        locked.wait_for_unit("multi-user.target")
        locked.wait_for_unit("lockedpools-setup.service")
        locked.succeed("zpool list -H -o name lockedcred | grep -qx lockedcred")
        locked.succeed("zpool list -H -o name lockedplain | grep -qx lockedplain")

    for unit, pool in [
        ("zfs-load-key-lockedcred.service", "lockedcred"),
        ("zfs-load-key-lockedplain.service", "lockedplain"),
    ]:
        with subtest(f"{unit} fails closed"):
            locked.wait_until_fails(f"systemctl is-active {unit}")
            # `failed`, not "successfully skipped". A ConditionPathExists on the
            # key file would leave the unit inactive with ConditionResult=no and
            # the boot would proceed with the datasets locked -- fail OPEN.
            locked.succeed(f"systemctl is-failed {unit}")
            locked.succeed(f"systemctl show -p Result {unit} | grep -qx Result=exit-code")
            locked.succeed(f"systemctl show -p ConditionResult {unit} | grep -qx ConditionResult=yes")
            # ... and the dataset is still locked.
            locked.succeed(f"zfs get -H -o value keystatus {pool} | grep -qx unavailable")

    with subtest("each key-delivery path failed for its own reason"):
        # useCredential = true: systemd itself refuses to start the unit.
        locked.succeed(
            "journalctl -b 0 -u zfs-load-key-lockedcred.service | grep -qi credential"
        )
        # useCredential = false: the module's own preflight check.
        locked.succeed(
            "journalctl -b 0 -u zfs-load-key-lockedplain.service"
            " | grep -q 'refusing to continue with locked datasets'"
        )

    with subtest("nothing consumed the locked datasets"):
        locked.fail("systemctl is-active --quiet cred-consumer.service")
        locked.fail("systemctl is-active --quiet plain-consumer.service")
        locked.fail("test -e /run/cred-consumer-ran")
        locked.fail("test -e /run/plain-consumer-ran")
        locked.fail("systemctl start mnt-locked.mount")
        locked.fail("findmnt -no FSTYPE /mnt/locked")
  '';
}
