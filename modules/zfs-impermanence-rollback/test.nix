{ pkgs, ... }:
let
  inherit (pkgs) lib;

  evalConfig = import (pkgs.path + "/nixos/lib/eval-config.nix");

  baseWiring = extra: {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      ./default.nix
      {
        boot.loader.grub.enable = false;
        system.stateVersion = "25.05";
        networking.hostId = "00000000";
        boot.initrd.systemd.enable = true;
        boot.supportedFilesystems = [ "zfs" ];
        fileSystems."/" = {
          device = "tank/root";
          fsType = "zfs";
        };
        fileSystems."/state" = {
          device = "tank/state";
          fsType = "zfs";
        };
        zfsWipeOnBoot = {
          enable = true;
          datasets = {
            root = {
              dataset = "tank/root";
              mountPoint = "/";
            };
            state = {
              dataset = "tank/state";
              mountPoint = "/state";
            };
          };
        };
      }
      extra
    ];
  };

  wiring = (evalConfig (baseWiring { })).config;

  stateUnit = wiring.boot.initrd.systemd.units."zfs-wipe-state.service".text;

  hasLine = text: line: lib.any (l: l == line) (lib.splitString "\n" text);

  enforcedNeededForBoot = wiring.fileSystems."/state".neededForBoot;

  anchoredOnSysroot = hasLine stateUnit "Before=sysroot.mount sysroot-state.mount";

  orderedAfterImport = hasLine stateUnit "After=zfs-import-tank.service";

  failedAssertions = c: map (a: a.message) (lib.filter (a: !a.assertion) c.assertions);

  # The guard rail fires when `neededForBoot` is taken away, and — the part that
  # keeps this from being vacuous — nothing else fires when it is not.
  guardRail =
    failedAssertions wiring == [ ]
    && lib.any (m: lib.hasInfix "is not neededForBoot" m) (
      failedAssertions
        (evalConfig (baseWiring {
          zfsWipeOnBoot.enforceNeededForBoot = false;
          fileSystems."/state".neededForBoot = lib.mkForce false;
        })).config
    );

  pool = "tank";

  # ---- option branches nothing else exercises -------------------------------
  # These are eval-level: each one is a distinct generated-unit shape, and
  # proving the shape is what matters. Booting a VM per branch would cost ~45
  # minutes each to assert the same strings.
  unitFor =
    extra: name:
    (evalConfig (baseWiring {
      zfsWipeOnBoot.datasets.${name} = extra;
    })).config.boot.initrd.systemd.units."zfs-wipe-${name}.service";

  # `.text` is the unit FILE; the rollback logic lives in the service's script.
  scriptFor =
    extra: name:
    (evalConfig (baseWiring {
      zfsWipeOnBoot.datasets.${name} = extra;
    })).config.boot.initrd.systemd.services."zfs-wipe-${name}".script;

  # onMissingSnapshot: three genuinely different behaviours when @blank is gone.
  # "fail" is the safe default -- refusing to boot beats silently keeping state
  # that was supposed to be discarded.
  missingFails = lib.hasInfix "Refusing to boot" (scriptFor { onMissingSnapshot = "fail"; } "state");
  missingCreates = lib.hasInfix "creating it from the CURRENT" (
    scriptFor { onMissingSnapshot = "create"; } "state"
  );
  missingIgnores = lib.hasInfix "skipping rollback" (
    scriptFor { onMissingSnapshot = "ignore"; } "state"
  );

  # failHard escalates a failed wipe to emergency.target. Without it a failed
  # rollback is just a failed unit and the machine boots carrying the state it
  # was meant to discard -- the silent version of the bug this recipe exists for.
  failHardEscalates = lib.hasInfix "OnFailure=emergency.target" (
    (unitFor { failHard = true; } "state").text
  );
  # failHard defaults to TRUE: the module fails safe, dropping to the initrd
  # emergency shell rather than booting with state that should have been gone.
  # It is disableable precisely because on a remote host with neither
  # emergencyAccess nor initrd SSH, emergency.target is an unreachable brick.
  failHardOnByDefault = lib.hasInfix "OnFailure=emergency.target" ((unitFor { } "state").text);
  failHardCanBeDisabled =
    !(lib.hasInfix "OnFailure=emergency.target" ((unitFor { failHard = false; } "state").text));

  # recursive controls whether child datasets go too. Getting this wrong is
  # silent in both directions: -r when you meant not to destroys nested state,
  # and omitting it leaves children un-wiped while the parent looks clean.
  recursiveByDefault = lib.hasInfix "zfs rollback -r " (scriptFor { } "state");
  nonRecursiveOmitsFlag =
    let
      t = scriptFor { recursive = false; } "state";
    in
    lib.hasInfix "zfs rollback \"" t && !(lib.hasInfix "rollback -r" t);
in
assert enforcedNeededForBoot;
assert anchoredOnSysroot;
assert orderedAfterImport;
assert guardRail;
assert missingFails;
assert missingCreates;
assert missingIgnores;
assert failHardEscalates;
assert failHardOnByDefault;
assert failHardCanBeDisabled;
assert recursiveByDefault;
assert nonRecursiveOmitsFlag;
pkgs.testers.runNixOSTest {
  name = "zfs-impermanence-rollback";

  nodes.machine =
    { config, ... }:
    {
      virtualisation = {
        emptyDiskImages = [ 3072 ];
        useBootLoader = true;
        useEFIBoot = true;
        mountHostNixStore = true;
      };
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
      boot.loader.timeout = 0;

      boot.initrd.systemd = {
        enable = true;
        emergencyAccess = true;
      };
      boot.supportedFilesystems = [ "zfs" ];
      networking.hostId = "deadbeef";
      boot.zfs.devNodes = "/dev/disk/by-uuid";

      specialisation.wiped.configuration =
        { config, lib, ... }:
        {
          imports = [ ./default.nix ];

          virtualisation.fileSystems = {
            "/" = {
              device = lib.mkForce "${pool}/root";
              fsType = lib.mkForce "zfs";
            };
            "/state" = {
              device = "${pool}/state";
              fsType = "zfs";
              neededForBoot = true;
            };
            "/persist" = {
              device = "${pool}/persist";
              fsType = "zfs";
              neededForBoot = true;
            };
          };

          services.openssh = {
            enable = true;
            settings.PermitRootLogin = "prohibit-password";
            hostKeys = [
              {
                path = "/persist/ssh/ssh_host_ed25519_key";
                type = "ed25519";
              }
            ];
            authorizedKeysFiles = lib.mkForce [ "/persist/ssh/authorized_keys.%u" ];
          };
          systemd.tmpfiles.rules = [ "d /persist/ssh 0700 root root -" ];

          zfsWipeOnBoot = {
            enable = true;
            datasets = {
              root = {
                dataset = "${pool}/root";
                mountPoint = "/";
              };
              state = {
                dataset = "${pool}/state";
                mountPoint = "/state";
              };
            };
          };

          boot.initrd.systemd.services.record-initrd-ordering = {
            description = "Record initrd unit ordering onto the persistent dataset";
            wantedBy = [ "initrd-fs.target" ];
            before = [ "initrd-fs.target" ];
            after = [
              "sysroot-state.mount"
              "sysroot-persist.mount"
            ];
            unitConfig.DefaultDependencies = "no";
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script =
              let
                sc = "${config.boot.initrd.systemd.package}/bin/systemctl";
              in
              ''
                mkdir -p /sysroot/persist/initrd
                {
                  echo "wipe_state_load=$(${sc} show -p LoadState --value zfs-wipe-state.service)"
                  echo "wipe_state_result=$(${sc} show -p Result --value zfs-wipe-state.service)"
                  echo "wipe_state_before=$(${sc} show -p Before --value zfs-wipe-state.service)"
                  echo "wipe_state_done=$(${sc} show -p ActiveEnterTimestampMonotonic --value zfs-wipe-state.service)"
                  echo "wipe_root_result=$(${sc} show -p Result --value zfs-wipe-root.service)"
                  echo "wipe_root_done=$(${sc} show -p ActiveEnterTimestampMonotonic --value zfs-wipe-root.service)"
                  echo "mount_state_load=$(${sc} show -p LoadState --value sysroot-state.mount)"
                  echo "mount_state_begin=$(${sc} show -p InactiveExitTimestampMonotonic --value sysroot-state.mount)"
                  echo "mount_root_begin=$(${sc} show -p InactiveExitTimestampMonotonic --value sysroot.mount)"
                } > /sysroot/persist/initrd/ordering
              '';
          };
        };
    };

  testScript =
    { nodes, ... }:
    let
      wiped = nodes.machine.specialisation.wiped.configuration.system.build.toplevel;
    in
    ''
      def ordering():
          raw = machine.succeed("cat /persist/initrd/ordering")
          out = {}
          for line in raw.strip().splitlines():
              k, _, v = line.partition("=")
              out[k] = v
          return out

      machine.wait_for_unit("multi-user.target")

      # ---- stage 1: build the pool the wiped configuration will boot from ----
      machine.succeed(
          "zpool create -f -o ashift=12 -o cachefile=none "
          "-O compression=lz4 -O atime=off -O mountpoint=legacy "
          "-O com.sun:auto-snapshot=false ${pool} /dev/vdb"
      )
      for ds in ["root", "state", "persist"]:
          machine.succeed(f"zfs create ${pool}/{ds}")

      # `root` and `state` get a blank snapshot; `persist` deliberately does not,
      # so nothing can roll it back even by accident.
      machine.succeed("zfs snapshot ${pool}/root@blank")
      machine.succeed("zfs snapshot ${pool}/state@blank")
      machine.fail("zfs list -H -t snapshot -o name ${pool}/persist@blank")

      machine.succeed("sync")
      machine.succeed("zpool export ${pool}")

      # ---- stage 2: boot the wiped configuration for the first time ----
      machine.succeed("${wiped}/bin/switch-to-configuration boot")
      machine.succeed("sync")
      machine.shutdown()
      machine.start()
      machine.wait_for_unit("multi-user.target")

      # We really are on ZFS root with two further ZFS datasets, and /state and
      # /persist are separate datasets rather than directories on root.
      assert machine.succeed("findmnt -no FSTYPE /").strip() == "zfs"
      assert machine.succeed("findmnt -no SOURCE /").strip() == "${pool}/root"
      assert machine.succeed("findmnt -no SOURCE /state").strip() == "${pool}/state"
      assert machine.succeed("findmnt -no SOURCE /persist").strip() == "${pool}/persist"

      # ---- stage 3: dirty every dataset ----
      machine.succeed("echo root-state > /EPHEMERAL_ROOT")
      machine.succeed("mkdir -p /state/deep/nested")
      machine.succeed("echo second-dataset-state > /state/EPHEMERAL_STATE")
      machine.succeed("echo second-dataset-state > /state/deep/nested/EPHEMERAL_STATE")
      machine.succeed("echo keep-me > /persist/PERSIST_MARKER")

      # An SSH identity that must survive the wipe. Under impermanence this is
      # the classic self-inflicted lockout: host keys and authorized_keys live
      # on paths that get rolled back unless they were deliberately persisted,
      # and the first wipe reboot then locks you out of your own machine.
      machine.succeed("mkdir -p /persist/ssh")
      machine.succeed(
          "ssh-keygen -q -t ed25519 -N ''' -C client -f /persist/ssh/client_key"
      )
      machine.succeed(
          "cp /persist/ssh/client_key.pub /persist/ssh/authorized_keys.root"
      )
      machine.succeed("chmod 0600 /persist/ssh/authorized_keys.root")
      machine.wait_for_unit("sshd.service")
      machine.wait_for_open_port(22)

      # Record the host key and prove a key login works BEFORE the wipe, so a
      # later failure cannot be blamed on the identity never having worked.
      hostkey_before = machine.succeed(
          "ssh-keyscan -t ed25519 127.0.0.1 2>/dev/null | grep -v '^#'"
      ).strip()
      assert hostkey_before, "no host key advertised before the wipe"
      machine.succeed(
          "ssh -i /persist/ssh/client_key -o StrictHostKeyChecking=no "
          "-o BatchMode=yes root@127.0.0.1 true"
      )

      # Negative control for the SSH case: an identity written to a
      # NON-persisted path. If this survives, the disk never wiped and every
      # "it still works" assertion below would be meaningless.
      machine.succeed("mkdir -p /etc/ssh-scratch && echo decoy > /etc/ssh-scratch/DECOY")

      machine.succeed("sync")

      # Sanity: they are all there before the reboot, so a post-reboot absence
      # cannot be explained by the write having failed.
      machine.succeed("test -e /EPHEMERAL_ROOT")
      machine.succeed("test -e /state/EPHEMERAL_STATE")
      machine.succeed("test -e /state/deep/nested/EPHEMERAL_STATE")
      machine.succeed("test -e /persist/PERSIST_MARKER")

      # ---- stage 4: the reboot the whole recipe is about ----
      machine.shutdown()
      machine.start()
      machine.wait_for_unit("multi-user.target")

      # 4a. The root dataset was rolled back.
      machine.fail("test -e /EPHEMERAL_ROOT")

      # 4b. THE SECOND neededForBoot DATASET was rolled back. This is the
      #     assertion the recipe exists for: it is mounted from the initrd, its
      #     mount unit is ordered after sysroot.mount, and the wipe still won.
      assert machine.succeed("findmnt -no SOURCE /state").strip() == "${pool}/state"
      machine.fail("test -e /state/EPHEMERAL_STATE")
      machine.fail("test -e /state/deep/nested/EPHEMERAL_STATE")
      machine.fail("test -e /state/deep")
      assert machine.succeed("ls -A /state").strip() == ""

      # 4c. …and this is not "the disks came up empty": the persisted dataset
      #     still holds exactly what was written to it before the reboot.
      assert machine.succeed("cat /persist/PERSIST_MARKER").strip() == "keep-me"

      # 4d. The SSH identity survived the wipe, and survived it INTACT.
      #     "sshd is up" is not the assertion that matters: a regenerated host
      #     key still yields a running sshd while breaking every client that
      #     pinned the old one -- including, on a remote-unlock host, the client
      #     that has to log into the initrd to unlock the disk.
      machine.wait_for_unit("sshd.service")
      machine.wait_for_open_port(22)
      hostkey_after = machine.succeed(
          "ssh-keyscan -t ed25519 127.0.0.1 2>/dev/null | grep -v '^#'"
      ).strip()
      assert hostkey_after == hostkey_before, (
          "host key changed across the wipe reboot: a pinning client is locked out"
      )

      # authorized_keys survived, so the same key still authenticates. Pin the
      # PRE-wipe host key via known_hosts so this is a real-world login rather
      # than one that would also pass against a regenerated identity.
      machine.succeed("test -e /persist/ssh/authorized_keys.root")
      machine.succeed(
          "printf '%s\\n' '" + hostkey_before + "' > /tmp/known_hosts"
      )
      machine.succeed(
          "ssh -i /persist/ssh/client_key -o StrictHostKeyChecking=yes "
          "-o UserKnownHostsFile=/tmp/known_hosts -o BatchMode=yes "
          "root@127.0.0.1 true"
      )

      # ...and the non-persisted decoy is gone, so the survival above is genuine
      # persistence rather than a wipe that never happened.
      machine.fail("test -e /etc/ssh-scratch/DECOY")

      # ---- stage 5: the ordering itself, as observed inside the initrd ----
      o = ordering()

      # The second dataset's mount unit exists in the initrd at all. Without
      # this the whole trap is vacuous: no unit, nothing to be ordered against.
      assert o["mount_state_load"] == "loaded", o

      # Both wipes ran, and ran successfully, in the initrd.
      assert o["wipe_state_load"] == "loaded", o
      assert o["wipe_state_result"] == "success", o
      assert o["wipe_root_result"] == "success", o

      # Trap 1: the anchor is sysroot.mount, not merely the dataset's own mount
      # unit. sysroot.mount cannot disappear; sysroot-state.mount can.
      before = o["wipe_state_before"].split()
      assert "sysroot.mount" in before, o
      assert "sysroot-state.mount" in before, o

      # …and the ordering was real at runtime, not just declared: the wipe of
      # the second dataset finished before its mount unit started.
      wipe_done = int(o["wipe_state_done"])
      mount_begin = int(o["mount_state_begin"])
      root_mount_begin = int(o["mount_root_begin"])
      assert wipe_done > 0, o
      assert mount_begin > 0, o
      assert root_mount_begin > 0, o
      assert wipe_done <= mount_begin, o
      assert wipe_done <= root_mount_begin, o
      assert int(o["wipe_root_done"]) <= root_mount_begin, o
    '';
}
