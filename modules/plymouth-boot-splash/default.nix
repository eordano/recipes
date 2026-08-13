# plymouth-boot-splash
#
# Two independent, opt-in flags for a desktop NixOS machine:
#
#   modules.bootConfig  -- systemd-boot on EFI, with the boot-time kernel
#                         cmdline editor enabled.
#   modules.plymouth    -- a graphical boot splash (Plymouth) that hides the
#                         kernel/systemd log spam behind `quiet`.
#
# TRAP 1 (security): `systemd-boot.editor = true` exposes the boot-menu
#   "e"-to-edit kernel command line. Anyone at the keyboard can append
#   `init=/bin/sh` (or `rd.break`, `systemd.unit=...`) and get a root shell
#   with no password -- a full local-root bypass of your login and disk
#   policy. Only tolerable on a *physically trusted* desktop. On laptops,
#   kiosks, servers, or anything that leaves your sight, set the editor to
#   false (the default here).
#
# TRAP 2 (diagnosability): under `quiet` + Plymouth the early boot goes dark,
#   which is exactly when a bad initrd (missing module, failed LUKS unlock,
#   unfound root device) leaves you staring at a frozen logo with no clue.
#   Keeping `initrd.verbose = true` lets the initrd stage still print, so
#   early-boot failures stay visible while the splash only hides the later,
#   less interesting log noise. It is a `mkDefault`, so a host can flip it.

{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    types
    ;
  cfg = config.modules;
  bootEnabled = cfg.bootConfig.enable;
  plymouthEnabled = cfg.plymouth.enable;
in
{
  options.modules.bootConfig = {
    enable = mkEnableOption "systemd-boot EFI loader defaults for a desktop";

    editor = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the systemd-boot boot-time kernel command-line editor.

        WARNING: this is a local-root bypass -- anyone at the keyboard can
        edit the cmdline (e.g. `init=/bin/sh`) and boot to an unauthenticated
        root shell. Enable ONLY on a physically trusted desktop.
      '';
    };

    canTouchEfiVariables = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Allow the installer/bootloader to modify EFI NVRAM variables.
        Set false on firmware where writing EFI vars is unsafe or read-only.
      '';
    };
  };

  options.modules.plymouth = {
    enable = mkEnableOption "graphical Plymouth boot splash";

    theme = mkOption {
      type = types.str;
      default = "square_hud";
      example = "spin";
      description = "Plymouth theme name (must be provided by themePackages).";
    };

    themePackages = mkOption {
      type = types.listOf types.package;
      default = with pkgs; [
        # A large third-party theme pack; override `selected_themes` to keep
        # the closure small. Swap for any package that installs your theme.
        (adi1090x-plymouth-themes.override {
          selected_themes = [
            "square_hud"
            "spin"
            "rings"
            "hexagon_2"
            "hexagon_dots"
            "circle_hud"
            "connect"
            "pie"
            "target_2"
          ];
        })
      ];
      defaultText = lib.literalExpression ''
        [ (pkgs.adi1090x-plymouth-themes.override { selected_themes = [ ... ]; }) ]
      '';
      description = "Packages that provide the Plymouth theme selected above.";
    };
  };

  config = mkMerge [
    (mkIf bootEnabled {
      boot.loader = {
        systemd-boot.enable = true;
        systemd-boot.editor = cfg.bootConfig.editor;
        efi.canTouchEfiVariables = cfg.bootConfig.canTouchEfiVariables;
      };
    })

    (mkIf plymouthEnabled {
      boot = {
        plymouth = {
          enable = true;
          theme = lib.mkDefault cfg.plymouth.theme;
          themePackages = cfg.plymouth.themePackages;
        };

        # `quiet` hides the late kernel/systemd log spam behind the splash.
        kernelParams = [ "quiet" ];

        # ...but keep the initrd talking so early-boot failures (LUKS, missing
        # modules, no root device) remain diagnosable behind the logo.
        # mkDefault so a host can still silence it deliberately.
        initrd.verbose = lib.mkDefault true;
      };
    })
  ];
}
