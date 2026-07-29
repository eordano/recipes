# Lifecycle test: first install -> remote unlock from the initrd over SSH ->
# key login -> wipe reboot -> unlock and log in AGAIN with the same pinned keys.
#
# The point is not that any single step works. It is that the SSH identities
# survive the wipe. Under impermanence there are TWO of them and they are
# separate: the initrd's host key (used by whoever unlocks the disk) and the
# running system's host key (used by everything afterwards). Lose either to a
# rollback and the machine is unreachable exactly when you need it -- the
# initrd one is worse, because the only way in is the thing that broke.
#
# Every SSH step below pins the key it expects via UserKnownHostsFile, so a
# regenerated identity fails the test instead of quietly reconnecting.
{ pkgs, ... }:
let
  inherit (pkgs) lib;
  pool = "tank";

in
pkgs.testers.runNixOSTest {
  name = "zfs-impermanence-remote-unlock";

  nodes = {
    server =
      { config, lib, ... }:
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

            # Only the WIPED configuration holds in the initrd. Putting the
            # backdoor on the base config would hang the disk-image build,
            # which boots a VM of that config to install the bootloader and
            # then waits for it to finish -- it never would.
            testing.initrdBackdoor = true;

            # Boot-from-SSH: the initrd brings up the network and an sshd whose
            # host identity is pinned to a fixed key, so the client can verify
            # the machine it is about to unlock.
            boot.initrd.network = {
              enable = true;
              ssh = {
                enable = true;
                port = 22;
                authorizedKeys = [ (lib.readFile ./test-keys/client.pub) ];
                # On the PERSISTED dataset, not on the wiped root. The module
                # asserts this, and the assertion is not pedantry: the initrd
                # secrets are assembled at activation, so a key on the wiped
                # path survives until the next `switch-to-configuration boot`
                # and then fails the deploy outright.
                hostKeys = [ "/persist/initrd-ssh-host-key" ];
              };
            };

            virtualisation.fileSystems = {
              "/" = {
                device = lib.mkForce "${pool}/root";
                fsType = lib.mkForce "zfs";
              };
              "/persist" = {
                device = "${pool}/persist";
                fsType = "zfs";
                neededForBoot = true;
              };
            };

            zfsWipeOnBoot = {
              enable = true;
              datasets.root = {
                dataset = "${pool}/root";
                mountPoint = "/";
              };
            };

            # The running system's own SSH identity lives on the persisted
            # dataset. This is the line that decides whether the first wipe
            # reboot locks you out.
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
          };
      };

    client =
      { ... }:
      {
        environment.etc."ssh-test/client" = {
          source = ./test-keys/client;
          mode = "0600";
        };
        environment.etc."ssh-test/initrd_host.pub".source = ./test-keys/initrd_host.pub;
      };
  };

  testScript =
    { nodes, ... }:
    let
      wiped = nodes.server.specialisation.wiped.configuration.system.build.toplevel;
    in
    ''
      start_all()
      client.wait_for_unit("network.target")

      def initrd_ssh(cmd):
          """SSH into the INITRD, pinning its host key. A regenerated initrd
          identity makes this fail rather than silently trusting a new one."""
          return client.succeed(
              "ssh -i /etc/ssh-test/client "
              "-o UserKnownHostsFile=/etc/ssh-test/initrd_known_hosts "
              "-o StrictHostKeyChecking=yes -o BatchMode=yes "
              f"root@server {cmd}"
          )

      # Pin the initrd host key from the public half we were built with.
      client.succeed(
          "printf 'server %s' \"$(cat /etc/ssh-test/initrd_host.pub)\" "
          "> /etc/ssh-test/initrd_known_hosts"
      )

      # ---- stage 1: first install, driven from the initrd over SSH ----
      # The machine is held in the initrd (initrdBackdoor), which is what a
      # real encrypted host does while it waits to be unlocked.
      server.wait_for_unit("multi-user.target")

      server.succeed(
          "zpool create -f -o ashift=12 -o cachefile=none "
          "-O compression=lz4 -O atime=off -O mountpoint=legacy "
          "-O com.sun:auto-snapshot=false ${pool} /dev/vdb"
      )
      server.succeed("zfs create ${pool}/root")
      server.succeed("zfs create ${pool}/persist")
      server.succeed("zfs snapshot ${pool}/root@blank")
      server.fail("zfs list -H -t snapshot -o name ${pool}/persist@blank")
      server.succeed("sync")

      # The initrd host key must exist INSIDE the VM: NixOS refuses a store
      # path for it (the store is world-readable), so the bootloader installer
      # copies it from a plain filesystem path at activation time. Mount the
      # persisted dataset where the booted system will have it, exactly as a
      # real install does, and put the key there -- NOT on the root that is
      # about to be wiped.
      server.succeed("mkdir -p /persist")
      server.succeed("mount -t zfs ${pool}/persist /persist")
      server.succeed("install -m 0600 ${./test-keys/initrd_host} /persist/initrd-ssh-host-key")

      # /persist stays mounted across this: `switch-to-configuration boot`
      # assembles the initrd secrets by copying the key off the LIVE
      # filesystem, so unmounting first fails the install outright with
      # "failed to create initrd secrets". That is the same failure a host
      # hits on its next deploy if the key sits on a wiped path -- which is
      # what the module's assertion exists to prevent.
      server.succeed("${wiped}/bin/switch-to-configuration boot")
      server.succeed("sync")

      server.succeed("umount /persist")
      server.succeed("zpool export ${pool}")
      server.succeed("sync")

      # ---- stage 2: boot the wiped configuration; unlock it over SSH ----
      server.shutdown()
      server.start()
      client.wait_until_succeeds("nc -z server 22", timeout=180)
      initrd_ssh("true")
      server.switch_root()
      server.wait_for_unit("multi-user.target")

      assert server.succeed("findmnt -no SOURCE /").strip() == "${pool}/root"
      assert server.succeed("findmnt -no SOURCE /persist").strip() == "${pool}/persist"

      # ---- stage 3: seed the running system's SSH identity + some state ----
      server.succeed("mkdir -p /persist/ssh")
      client.succeed(
          "ssh-keygen -y -f /etc/ssh-test/client > /tmp/client.pub"
      )
      pub = client.succeed("cat /tmp/client.pub").strip()
      server.succeed(f"printf '%s\\n' '{pub}' > /persist/ssh/authorized_keys.root")
      server.succeed("chmod 0600 /persist/ssh/authorized_keys.root")
      server.wait_for_unit("sshd.service")
      server.wait_for_open_port(22)

      sys_hostkey = server.succeed(
          "cat /persist/ssh/ssh_host_ed25519_key.pub"
      ).strip()
      client.succeed(
          f"printf 'server %s\\n' '{sys_hostkey}' > /etc/ssh-test/sys_known_hosts"
      )
      client.succeed(
          "ssh -i /etc/ssh-test/client "
          "-o UserKnownHostsFile=/etc/ssh-test/sys_known_hosts "
          "-o StrictHostKeyChecking=yes -o BatchMode=yes root@server true"
      )

      server.succeed("echo keep-me > /persist/PERSIST_MARKER")
      server.succeed("echo wipe-me > /EPHEMERAL_ROOT")
      server.succeed("sync")

      # ---- stage 4: the wipe reboot, unlocked remotely once more ----
      server.shutdown()
      server.start()
      client.wait_until_succeeds("nc -z server 22", timeout=180)

      # 4a. THE INITRD IDENTITY SURVIVED. The same pinned host key still
      #     verifies, so the operator who has to unlock this machine can still
      #     reach it. If this regressed there would be no other way in.
      initrd_ssh("true")
      server.switch_root()
      server.wait_for_unit("multi-user.target")

      # 4b. The wipe actually happened.
      server.fail("test -e /EPHEMERAL_ROOT")

      # 4c. ...and this is not "the disk came up empty".
      assert server.succeed("cat /persist/PERSIST_MARKER").strip() == "keep-me"

      # 4d. THE RUNNING SYSTEM'S IDENTITY SURVIVED TOO, unchanged, and the same
      #     key still authenticates -- pinned against the PRE-wipe host key.
      server.wait_for_unit("sshd.service")
      server.wait_for_open_port(22)
      assert server.succeed("cat /persist/ssh/ssh_host_ed25519_key.pub").strip() == sys_hostkey
      client.succeed(
          "ssh -i /etc/ssh-test/client "
          "-o UserKnownHostsFile=/etc/ssh-test/sys_known_hosts "
          "-o StrictHostKeyChecking=yes -o BatchMode=yes root@server true"
      )
    '';
}
