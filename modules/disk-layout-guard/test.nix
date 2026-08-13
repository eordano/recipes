{ pkgs, ... }:
let
  evalFor =
    extra:
    (pkgs.nixos (
      { lib, ... }:
      {
        imports = [
          ./default.nix
          extra
        ];

        fileSystems."/" = lib.mkDefault {
          device = "/dev/null";
          fsType = "ext4";
        };
        boot.loader.grub.enable = false;
        networking.hostId = "deadbeef";
        system.stateVersion = "24.05";
      }
    )).config;

  guardFor = extra: (evalFor extra).system.preSwitchChecks.diskLayout or "";

  scripts = {
    ok = guardFor { };

    missingDevice = guardFor {
      fileSystems."/srv" = {
        device = "/dev/disk/by-partlabel/definitely-not-here";
        fsType = "ext4";
      };
    };

    skippedByNofail = guardFor {
      fileSystems."/srv" = {
        device = "/dev/disk/by-partlabel/definitely-not-here";
        fsType = "ext4";
        options = [ "nofail" ];
      };
    };

    skippedByIgnore = guardFor {
      modules.diskLayoutGuard.ignoreDevices = [ "/dev/disk/by-partlabel/definitely-not-here" ];
      fileSystems."/srv" = {
        device = "/dev/disk/by-partlabel/definitely-not-here";
        fsType = "ext4";
      };
    };

    missingPool = guardFor {
      fileSystems."/srv" = {
        device = "ghostpool/data";
        fsType = "zfs";
      };
    };

    cryptDropped = guardFor {
      fileSystems."/srv" = {
        device = "tank/data";
        fsType = "zfs";
      };
    };

    cryptDeclared = guardFor {
      fileSystems."/srv" = {
        device = "tank/data";
        fsType = "zfs";
      };
      boot.initrd.luks.devices.tcrypt.device = "/dev/loop0";
    };

    disabled = guardFor {
      modules.diskLayoutGuard.enable = false;
      fileSystems."/srv" = {
        device = "/dev/disk/by-partlabel/definitely-not-here";
        fsType = "ext4";
      };
    };
  };
in
pkgs.testers.nixosTest {
  name = "disk-layout-guard";

  nodes.machine =
    { pkgs, ... }:
    {
      boot.supportedFilesystems = [ "zfs" ];
      networking.hostId = "cafebabe";

      environment.systemPackages = with pkgs; [
        cryptsetup
        zfs
      ];

      environment.etc = pkgs.lib.mapAttrs' (name: text: {
        name = "guard/${name}";
        value = {
          inherit text;
          mode = "0555";
        };
      }) scripts;

      virtualisation = {
        memorySize = 2048;
        diskSize = 4096;
      };
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")

    def guard(name):
        return machine.execute(f"bash /etc/guard/{name} 2>&1")

    with subtest("a configuration whose storage exists passes"):
        rc, out = guard("ok")
        assert rc == 0, out

    with subtest("a declared device that does not exist is refused"):
        rc, out = guard("missingDevice")
        assert rc != 0, out
        assert "definitely-not-here" in out, out
        assert "does not exist here" in out, out

    with subtest("nofail mounts are not boot-critical and are skipped"):
        rc, out = guard("skippedByNofail")
        assert rc == 0, out

    with subtest("ignoreDevices exempts a device"):
        rc, out = guard("skippedByIgnore")
        assert rc == 0, out

    with subtest("the guard can be switched off"):
        # enable = false emits no check at all, so the file is empty rather
        # than a script that passes.
        assert machine.succeed("wc -c < /etc/guard/disabled").strip() == "0"
        rc, out = guard("disabled")
        assert rc == 0, out

    with subtest("a declared pool that is not imported is refused"):
        rc, out = guard("missingPool")
        assert rc != 0, out
        assert "zpool:ghostpool" in out, out

    with subtest("build a dm-crypt backed pool"):
        machine.succeed("truncate -s 512M /var/crypt.img")
        machine.succeed("losetup /dev/loop0 /var/crypt.img")
        machine.succeed("echo -n hunter2 > /var/key")
        machine.succeed(
            "cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 "
            "--pbkdf-force-iterations 1000 --batch-mode /dev/loop0 /var/key"
        )
        machine.succeed("cryptsetup open --key-file /var/key /dev/loop0 tcrypt")
        machine.succeed("zpool create -f tank /dev/mapper/tcrypt")
        machine.succeed("zfs create tank/data")
        vdevs = machine.succeed("zpool list -vHP tank")
        assert "/dev/mapper/tcrypt" in vdevs, vdevs

    with subtest("dropping LUKS from a config whose pool sits on dm-crypt is refused"):
        # The pool is reachable and the running system is fine, so nothing else
        # notices that the incoming generation has no way to unlock the disks at
        # the next boot.
        rc, out = guard("cryptDropped")
        assert rc != 0, out
        assert "backed by dm-crypt" in out, out
        assert "no boot.initrd.luks.devices" in out, out

    with subtest("the same config keeps passing while it still declares LUKS"):
        rc, out = guard("cryptDeclared")
        assert rc == 0, out

    print("disk-layout-guard test passed")
  '';
}
