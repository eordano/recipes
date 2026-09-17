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

        kernelParams = [ "quiet" ];

        initrd.verbose = lib.mkDefault true;
      };
    })
  ];
}
