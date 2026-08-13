{
  pkgs,
  lib ? pkgs.lib,
  ...
}:
let
  espMount = "/boot";
  mirrorMount = "/boot-mirror";
  recoveryDir = "/var/lib/boot-recovery";

  recoveryKernel = "recovery-pinned-bzImage.efi";
  recoveryInitrd = "recovery-pinned-initrd.efi";
  recoveryEntry = "recovery-shell-init.conf";

  marker = "pinnedrecovery=confirmed";

  mirrorSerial = "espmirror";
  payloadSerial = "recoverypl";
  mirrorDev = "/dev/disk/by-id/virtio-${mirrorSerial}";
  payloadDev = "/dev/disk/by-id/virtio-${payloadSerial}";

  evalBase = {
    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = false;
    system.stateVersion = "25.05";
    fileSystems."/" = {
      device = "/dev/vda2";
      fsType = "ext4";
    };
    fileSystems.${espMount} = {
      device = "/dev/disko-would-put-this-here";
      fsType = "vfat";
      options = [ "defaults" ];
    };
    fileSystems.${mirrorMount} = {
      device = "/dev/disko-would-put-this-here-too";
      fsType = "vfat";
      options = [ "defaults" ];
    };
  };

  evalWith =
    extra:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        ./default.nix
        evalBase
        extra
      ];
    }).config;

  wired = evalWith {
    boot.mirroredEsp = {
      enable = true;
      primary = {
        mountPoint = espMount;
        device = "/dev/disk/by-uuid/1111-AAAA";
      };
      mirror = {
        mountPoint = mirrorMount;
        device = "/dev/disk/by-uuid/2222-BBBB";
      };
      recovery = {
        enable = true;
        directory = recoveryDir;
        efiFiles = [
          recoveryKernel
          recoveryInitrd
        ];
        entryFiles = [ recoveryEntry ];
      };
    };
  };

  badName = evalWith {
    boot.mirroredEsp = {
      enable = true;
      primary.mountPoint = espMount;
      recovery = {
        enable = true;
        entryFiles = [ "nixos-recovery.conf" ];
      };
    };
  };

  payloadOnEsp = evalWith {
    boot.mirroredEsp = {
      enable = true;
      primary.mountPoint = espMount;
      recovery = {
        enable = true;
        directory = espMount + "/recovery";
        efiFiles = [ recoveryKernel ];
      };
    };
  };

  failing = c: builtins.filter (a: !a.assertion) c.assertions;
  msgs = c: lib.concatStringsSep "\n" (map (a: a.message) (failing c));
  hasFailureMentioning =
    c: needle: builtins.length (builtins.filter (a: lib.hasInfix needle a.message) (failing c)) > 0;

  install = wired.boot.loader.systemd-boot.extraInstallCommands;

  # `qemu-vm.nix` replaces `fileSystems` wholesale with
  # `mkVMOverride config.virtualisation.fileSystems`, so a VM test can NEVER
  # observe a module's declared mounts. These four facts are therefore checked
  # in a plain non-VM evaluation; the VM below mounts the two ESPs by hand with
  # the same options this evaluation proves the module declares.
  evalChecks = {
    "primary device is mkForce'd over the disko-style definition" =
      wired.fileSystems.${espMount}.device == "/dev/disk/by-uuid/1111-AAAA";
    "mirror device is mkForce'd over the disko-style definition" =
      wired.fileSystems.${mirrorMount}.device == "/dev/disk/by-uuid/2222-BBBB";
    "primary mount options ADD umask=0077 without dropping the existing ones" =
      builtins.elem "umask=0077" wired.fileSystems.${espMount}.options
      && builtins.elem "defaults" wired.fileSystems.${espMount}.options;
    "mirror mount options ADD umask=0077 without dropping the existing ones" =
      builtins.elem "umask=0077" wired.fileSystems.${mirrorMount}.options
      && builtins.elem "defaults" wired.fileSystems.${mirrorMount}.options;
    "the install hook restores the recovery kernel into <ESP>/EFI/nixos" =
      lib.hasInfix "${recoveryDir}/${recoveryKernel}" install
      && lib.hasInfix "${espMount}/EFI/nixos/" install;
    "the install hook restores the recovery entry into <ESP>/loader/entries" =
      lib.hasInfix "${recoveryDir}/${recoveryEntry}" install
      && lib.hasInfix "${espMount}/loader/entries/${recoveryEntry}" install;
    "the install hook mirrors the ESP with --delete" =
      lib.hasInfix "--delete" install && lib.hasInfix "${espMount}/ ${mirrorMount}/" install;
    "the wired config has no failing assertions" = failing wired == [ ];
    "a nixos-*.conf recovery entry is rejected (Trap 1)" =
      hasFailureMentioning badName "must not match nixos-*.conf";
    "a recovery payload staged inside the ESP is rejected" =
      hasFailureMentioning payloadOnEsp "The installer garbage-collects";
  };

  evalFailures = lib.attrNames (lib.filterAttrs (_: ok: !ok) evalChecks);
in
assert lib.assertMsg (evalFailures == [ ]) (
  "eval-time checks failed: "
  + lib.concatStringsSep "; " evalFailures
  + lib.optionalString (failing wired != [ ]) ("\nwired assertions: " + msgs wired)
);
pkgs.testers.runNixOSTest {
  name = "systemd-boot-mirrored-esp";

  # NOTE ON `lib/nixos-test-topology`: deliberately NOT used here. That library
  # exists to take IP assignment away from the test framework for MULTI-NODE
  # tests. This test has exactly one booted machine and no network traffic at
  # all -- the extra `nodes` below are never started, they exist only so the
  # test has three distinct `system.build.toplevel`s to build generations from.
  # There is no subnet, no route and no forward hook to get wrong, so importing
  # the topology library would add a dependency and buy nothing.

  nodes =
    let
      common =
        { pkgs, ... }:
        {
          imports = [ ./default.nix ];

          boot.loader.systemd-boot.enable = true;
          boot.loader.systemd-boot.configurationLimit = 2;
          boot.loader.efi.canTouchEfiVariables = true;
          system.switch.enable = true;

          # Needed for machine-id to be persisted between reboots (upstream
          # nixos/tests/systemd-boot.nix says the same).
          environment.etc."machine-id".text = "1234567890abcdef1234567890abcdef\n";

          environment.systemPackages = with pkgs; [
            diffutils
            dosfstools
            e2fsprogs
          ];

          boot.mirroredEsp = {
            enable = true;
            primary.mountPoint = espMount;
            mirror.mountPoint = mirrorMount;
            recovery = {
              enable = true;
              directory = recoveryDir;
              efiFiles = [
                recoveryKernel
                recoveryInitrd
              ];
              entryFiles = [ recoveryEntry ];
            };
          };
        };

      # Never booted. `useBootLoader` is forced off so the test driver does not
      # build a disk image for a VM that only exists to contribute a toplevel.
      variant = mods: {
        imports = [
          common
          mods
        ];
        virtualisation.useBootLoader = lib.mkForce false;
        virtualisation.useNixStoreImage = lib.mkForce false;
        virtualisation.mountHostNixStore = lib.mkForce true;
      };
    in
    {
      machine =
        { nodes, ... }:
        {
          imports = [ common ];

          virtualisation.useBootLoader = true;
          virtualisation.useEFIBoot = true;

          virtualisation.emptyDiskImages = [
            {
              size = 512;
              driveConfig.deviceExtraOpts.serial = mirrorSerial;
            }
            {
              size = 512;
              driveConfig.deviceExtraOpts.serial = payloadSerial;
            }
          ];

          system.extraDependencies = [
            nodes.variantA.system.build.toplevel
            nodes.variantB.system.build.toplevel
          ];
        };

      # Two extra system closures with DIFFERENT initrds, so that rolling past
      # `configurationLimit` really orphans a kernel/initrd on the ESP instead
      # of leaving the same file in the keep set forever (which would make the
      # garbage-collection assertions vacuous). The initrd difference is
      # asserted explicitly in the testScript.
      variantA = variant { boot.initrd.availableKernelModules = [ "loop" ]; };
      variantB = variant { boot.initrd.availableKernelModules = [ "dm_mod" ]; };
    };

  testScript =
    { nodes, ... }:
    let
      variantAsys = nodes.variantA.system.build.toplevel;
      variantBsys = nodes.variantB.system.build.toplevel;
      machineSys = nodes.machine.system.build.toplevel;
    in
    ''
      ESP = "${espMount}"
      MIRROR = "${mirrorMount}"
      PAYLOAD = "${recoveryDir}"
      REC_KERNEL = "${recoveryKernel}"
      REC_INITRD = "${recoveryInitrd}"
      REC_ENTRY = "${recoveryEntry}"
      MARKER = "${marker}"


      def entry_field(conf, field):
          out = machine.succeed("sed -n 's/^" + field + " //p' " + conf).strip()
          assert out, "no '" + field + "' line in " + conf
          return out.split("\n")[0].strip()


      def gen_conf(n):
          out = machine.succeed(
              "grep -l 'version Generation " + str(n) + " NixOS' " + ESP + "/loader/entries/nixos-*.conf"
          ).strip()
          return out.split("\n")[0]


      def install(system_path):
          machine.succeed("nix-env -p /nix/var/nix/profiles/system --set " + system_path)
          machine.succeed(system_path + "/bin/switch-to-configuration boot")
          machine.succeed("sync")


      def esps_identical(label):
          """Recursive, content-level equality of the two ESPs."""
          machine.succeed("sync")
          # 1. same tree shape (files AND directories, at every depth)
          machine.succeed("cd " + ESP + " && find . -mindepth 1 | sort > /tmp/primary.list")
          machine.succeed("cd " + MIRROR + " && find . -mindepth 1 | sort > /tmp/mirror.list")
          machine.succeed("diff -u /tmp/primary.list /tmp/mirror.list")
          # 2. same bytes in every regular file
          machine.succeed(
              "cd " + ESP + " && find . -type f -print0 | sort -z | xargs -0r sha256sum > /tmp/primary.sums"
          )
          machine.succeed(
              "cd " + MIRROR + " && find . -type f -print0 | sort -z | xargs -0r sha256sum > /tmp/mirror.sums"
          )
          machine.succeed("diff -u /tmp/primary.sums /tmp/mirror.sums")
          # 3. belt and braces: a plain recursive diff of the two trees
          machine.succeed("diff -r " + ESP + " " + MIRROR)
          # 4. and the comparison must not be trivially true on an empty ESP
          n = int(machine.succeed("find " + ESP + " -type f | wc -l").strip())
          size = int(machine.succeed("du -sk " + ESP + " | cut -f1").strip())
          assert n >= 6, label + ": ESP holds only " + str(n) + " files, comparison near-vacuous"
          assert size >= 10000, label + ": ESP holds only " + str(size) + "K, comparison near-vacuous"


      def recovery_payload_present(label):
          machine.succeed("test -f " + ESP + "/EFI/nixos/" + REC_KERNEL)
          machine.succeed("test -f " + ESP + "/EFI/nixos/" + REC_INITRD)
          machine.succeed("test -f " + ESP + "/loader/entries/" + REC_ENTRY)
          # PRESENT is not enough: the entry must still POINT AT files that are
          # there, and those files must still be the pinned bytes.
          rl = entry_field(ESP + "/loader/entries/" + REC_ENTRY, "linux")
          ri = entry_field(ESP + "/loader/entries/" + REC_ENTRY, "initrd")
          machine.succeed("test -s " + ESP + rl)
          machine.succeed("test -s " + ESP + ri)
          machine.succeed("cmp " + ESP + rl + " " + PAYLOAD + "/" + REC_KERNEL)
          machine.succeed("cmp " + ESP + ri + " " + PAYLOAD + "/" + REC_INITRD)
          return rl, ri


      machine.start()
      machine.wait_for_unit("multi-user.target")

      with subtest("fixtures: a second ESP and a persistent payload disk"):
          machine.succeed("test -b ${mirrorDev}")
          machine.succeed("test -b ${payloadDev}")
          # qemu-vm.nix mkVMOverrides `fileSystems`, so the module's own mount
          # declarations (proven at eval time above) cannot apply here. Mount
          # both ESPs by hand with the SAME options the module declares --
          # matching umask on both sides is what keeps `rsync -a` from having
          # to chmod on vfat.
          machine.succeed("mount -o remount,umask=0077 " + ESP)
          machine.succeed("mkfs.vfat -F 32 -n ESPMIRROR ${mirrorDev}")
          machine.succeed("mkdir -p " + MIRROR)
          machine.succeed("mount -t vfat -o umask=0077 ${mirrorDev} " + MIRROR)
          machine.succeed("mkfs.ext4 -q -F -L recovery ${payloadDev}")
          machine.succeed("mkdir -p " + PAYLOAD)
          machine.succeed("mount ${payloadDev} " + PAYLOAD)

      with subtest("stage the pinned recovery payload outside the ESP and the store"):
          g1 = gen_conf(1)
          g1_linux = entry_field(g1, "linux")
          g1_initrd = entry_field(g1, "initrd")
          g1_options = entry_field(g1, "options")

          machine.succeed("cp " + ESP + g1_linux + " " + PAYLOAD + "/" + REC_KERNEL)
          machine.succeed("cp " + ESP + g1_initrd + " " + PAYLOAD + "/" + REC_INITRD)

          conf = "\n".join([
              "title NixOS recovery (pinned)",
              "sort-key zz-recovery",
              "linux /EFI/nixos/" + REC_KERNEL,
              "initrd /EFI/nixos/" + REC_INITRD,
              "options " + g1_options + " " + MARKER,
          ])
          machine.succeed(
              "cat > " + PAYLOAD + "/" + REC_ENTRY + " <<'ENTRYEOF'\n" + conf + "\nENTRYEOF"
          )

      with subtest("instrument: unpinned decoys the ESP collector MUST delete"):
          # Without these, "the recovery files are still there" could just mean
          # "garbage collection never ran". These two files are the control:
          # they sit in exactly the places the collector scans, are owned by no
          # generation, and are not restored by the module -- so they MUST
          # disappear on the very next install. If they survive, every
          # survival assertion below is worthless and the test says so.
          machine.succeed("echo control > " + ESP + "/EFI/nixos/unpinned-control.efi")
          machine.succeed("printf 'title decoy\\n' > " + ESP + "/loader/entries/nixos-decoy-control.conf")
          # And a stray in the mirror, to prove rsync --delete really prunes.
          machine.succeed("echo stale > " + MIRROR + "/stale-junk-file")

      with subtest("generation 2: install runs the module's hook"):
          install("${variantAsys}")

          # THE INSTRUMENT. Both decoys gone => the collector ran, over these
          # exact directories, deleting exactly this class of file.
          machine.fail("test -e " + ESP + "/EFI/nixos/unpinned-control.efi")
          machine.fail("test -e " + ESP + "/loader/entries/nixos-decoy-control.conf")

          recovery_payload_present("gen2")

          machine.fail("test -e " + MIRROR + "/stale-junk-file")
          esps_identical("gen2")

          gen2_initrd = entry_field(gen_conf(2), "initrd")
          machine.succeed("test -f " + ESP + gen2_initrd)

      with subtest("generations 3 and 4: roll past configurationLimit = 2"):
          install("${variantBsys}")
          gen3_initrd = entry_field(gen_conf(3), "initrd")
          install("${machineSys}")
          gen4_initrd = entry_field(gen_conf(4), "initrd")

          # Guard against the assertions below going vacuous: the three system
          # closures must really have distinct initrds on the ESP.
          assert len({gen2_initrd, gen3_initrd, gen4_initrd}) == 3, (
              "generations share an initrd (" + gen2_initrd + ", " + gen3_initrd
              + ", " + gen4_initrd + "); the GC assertions would prove nothing"
          )

      with subtest("generation GC really happened"):
          # configurationLimit = 2 dropped generations 1 and 2 ...
          machine.fail("grep -l 'version Generation 1 NixOS' " + ESP + "/loader/entries/nixos-*.conf")
          machine.fail("grep -l 'version Generation 2 NixOS' " + ESP + "/loader/entries/nixos-*.conf")
          machine.succeed("grep -l 'version Generation 3 NixOS' " + ESP + "/loader/entries/nixos-*.conf")
          machine.succeed("grep -l 'version Generation 4 NixOS' " + ESP + "/loader/entries/nixos-*.conf")
          # ... and with them, generation 2's initrd FILE. This is the trap:
          # an unpinned recovery entry pointing at an old generation would be
          # dangling exactly here.
          machine.fail("test -e " + ESP + gen2_initrd)

      with subtest("the recovery entry SURVIVED generation garbage collection"):
          rl, ri = recovery_payload_present("gen4")
          # the mirror carries the surviving recovery payload too
          machine.succeed("test -s " + MIRROR + rl)
          machine.succeed("test -s " + MIRROR + ri)
          machine.succeed("test -f " + MIRROR + "/loader/entries/" + REC_ENTRY)
          machine.succeed("cmp " + ESP + rl + " " + MIRROR + rl)
          machine.succeed("cmp " + ESP + ri + " " + MIRROR + ri)
          esps_identical("gen4")

      with subtest("end to end: the surviving recovery entry actually boots"):
          # systemd-boot rewrites loader.conf on every install, so this is done
          # after the last install and only affects which entry is selected.
          machine.succeed(
              "printf 'timeout 2\\ndefault " + REC_ENTRY + "\\n' > " + ESP + "/loader/loader.conf"
          )
          machine.succeed("sync")
          machine.shutdown()
          machine.start()
          machine.wait_for_unit("multi-user.target")
          # The marker only exists on the pinned entry's `options` line, so a
          # kernel command line carrying it can only have come from booting the
          # recovery entry off the pinned kernel+initrd.
          machine.succeed("grep -q ' " + MARKER + "' /proc/cmdline")
          machine.succeed("test -f " + ESP + "/EFI/nixos/" + REC_KERNEL)
          machine.succeed("test -f " + ESP + "/EFI/nixos/" + REC_INITRD)
          machine.succeed("test -f " + ESP + "/loader/entries/" + REC_ENTRY)
    '';
}
