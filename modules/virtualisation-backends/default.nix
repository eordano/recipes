# virtualisation-backends
#
# A NixOS module that gates four VM/container back-ends behind one boolean each:
#   - VirtualBox host
#   - VirtualBox guest additions
#   - QEMU/KVM via virt-manager (libvirtd)
#   - Waydroid (Android container)
#
# The value is not the wiring, it is the traps encoded below. See README.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkIf mkMerge mkOption types;
  cfg = config.modules.virtualisation;
in
{
  options.modules.virtualisation = {
    virtualbox = mkOption {
      description = "Enable VirtualBox host.";
      type = types.bool;
      default = false;
    };
    virtualbox-guest = mkOption {
      description = "Enable VirtualBox guest additions (use inside a VirtualBox VM).";
      type = types.bool;
      default = false;
    };
    virtmanager = mkOption {
      description = "Enable QEMU/KVM virtualisation with virt-manager (libvirtd).";
      type = types.bool;
      default = false;
    };
    waydroid = mkOption {
      description = "Enable the Waydroid Android container.";
      type = types.bool;
      default = false;
    };

    # The unprivileged user that should be able to drive these back-ends.
    # It is added to the vboxusers / libvirtd groups and runs the QEMU
    # processes. Set this to your login user.
    user = mkOption {
      description = "Login user granted access to the enabled back-ends.";
      type = types.str;
      example = "alice";
      default = "user";
    };

    # Primary group of `user`, used for the QEMU process group. Defaults to
    # "users", which is the usual login group on NixOS.
    group = mkOption {
      description = "Primary group of `user`, used as the QEMU process group.";
      type = types.str;
      default = "users";
    };
  };

  # IMPORTANT: this MUST be `mkMerge`, never a `//`-chain of `mkIf` blocks.
  # `//` (attrset update) keeps only the LAST attribute and silently drops
  # every earlier block — you get a config that type-checks, builds, and is
  # wrong, with no error. `mkMerge` is the module-system-aware combinator that
  # actually merges the branches. Only ever use `//` between plain attrsets
  # that carry no module-system properties (no mkIf/mkMerge/mkDefault inside).
  config = mkMerge [

    (mkIf cfg.virtualbox {
      environment.systemPackages = with pkgs; [ virtualbox ];
      virtualisation.virtualbox.host = {
        enable = true;
        enableExtensionPack = true;
        enableKvm = true;

        # TRAP: keep this false. The KVM backend is NAT-only; enabling the
        # host-only `vboxnet0` interface trips a NixOS assertion that refuses
        # the build. If you genuinely need host-only networking, you cannot
        # also use `enableKvm = true` above.
        addNetworkInterface = false;
      };
      users.extraGroups.vboxusers.members = [ cfg.user ];
    })

    (mkIf cfg.virtualbox-guest {
      # NOTE: recent nixpkgs removed the `x11` sub-option from
      # `virtualbox.guest` — do not try to set it here. `dragAndDrop` DOES
      # still exist (default true); only the old lowercase `draganddrop`
      # spelling is gone, behind a rename shim.
      virtualisation.virtualbox.guest.enable = true;
    })

    (mkIf cfg.virtmanager {
      virtualisation = {
        libvirtd = {
          enable = true;
          qemu = {
            # TRAP: the default `qemu_full` pulls in the ceph and glusterfs
            # storage backends. They are useless on a desktop VM host and, on
            # current unstable (gcc15), ceph fails to COMPILE — which would
            # block this host's entire system closure from building. Drop them.
            package = pkgs.qemu_full.override {
              cephSupport = false;
              glusterfsSupport = false;
            };
            runAsRoot = true;
            # Keep libvirt's default per-VM mount-namespace isolation (each
            # QEMU sees a minimal, private /dev). Do NOT add `namespaces = []`
            # here: that disables it machine-wide and hands a guest-escape the
            # host's full /dev view. Only the user/group override is needed.
            verbatimConfig = ''
              user = "${cfg.user}"
              group = "${cfg.group}"
            '';
            swtpm.enable = true; # software TPM, needed for Windows 11 guests
          };
        };
        spiceUSBRedirection.enable = true;
      };

      programs.dconf.enable = true; # virt-manager stores settings in dconf
      environment.systemPackages = with pkgs; [
        virt-manager
        qemu
        virtiofsd
        libvirt
      ];
      users.users.${cfg.user}.extraGroups = [ "libvirtd" ];
    })

    (mkIf cfg.waydroid {
      virtualisation.waydroid.enable = true;
      environment.systemPackages = with pkgs; [ waydroid ];
    })
  ];
}
