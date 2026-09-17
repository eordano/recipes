{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkIf
    mkMerge
    mkOption
    types
    ;
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

    user = mkOption {
      description = "Login user granted access to the enabled back-ends.";
      type = types.str;
      example = "alice";
      default = "user";
    };

    group = mkOption {
      description = "Primary group of `user`, used as the QEMU process group.";
      type = types.str;
      default = "users";
    };
  };

  config = mkMerge [

    (mkIf cfg.virtualbox {
      environment.systemPackages = with pkgs; [ virtualbox ];
      virtualisation.virtualbox.host = {
        enable = true;
        enableExtensionPack = true;
        enableKvm = true;

        addNetworkInterface = false;
      };
      users.extraGroups.vboxusers.members = [ cfg.user ];
    })

    (mkIf cfg.virtualbox-guest {
      virtualisation.virtualbox.guest.enable = true;
    })

    (mkIf cfg.virtmanager {
      virtualisation = {
        libvirtd = {
          enable = true;
          qemu = {
            package = pkgs.qemu_full.override {
              cephSupport = false;
            };
            runAsRoot = true;
            verbatimConfig = ''
              user = "${cfg.user}"
              group = "${cfg.group}"
            '';
            swtpm.enable = true;
          };
        };
        spiceUSBRedirection.enable = true;
      };

      programs.dconf.enable = true;
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
