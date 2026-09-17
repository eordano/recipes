{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (pkgs.stdenv) isLinux;

  linuxOnly = ps: if isLinux then ps else [ ];

  configurations = with pkgs; {
    nix-helpers = {
      description = "tools that make nix easier to use";
      packages = [
        any-nix-shell
        nixfmt-rfc-style
        nix-index
        nix-prefetch
        nix-tree
        nvd
      ]
      ++ lib.optionals (pkgs.stdenv.hostPlatform.system != "aarch64-linux") [
        cachix
      ]
      ++ linuxOnly [
        nixos-shell
      ];
    };

    develop = {
      description = "CLI development tools and utilities";
      packages = [
        gh
        go
        cargo
        rustc
        rust-analyzer
        clippy
        rustfmt
        openssl
        pkg-config
        jq
      ]
      ++ linuxOnly [
        cargo-watch
        sshfs
        fuse3
        gdb
      ];
    };

    desktop = {
      description = "windowed / GUI applications";
      packages = [
        vlc
        inkscape
        ffmpeg-full
        imagemagick
      ];
    };

    sysadmin-tools = {
      description = "sysadmin tools such as lsof, htop, ripgrep";
      packages = [
        bat
        btop
        eza
        fd
        file
        fzf
        htop
        lsof
        nmap
        ripgrep
        rsync
        tcpdump
        tree
        unzip
      ]
      ++ linuxOnly [
        ethtool
        iotop
        lm_sensors
        strace
        usbutils
        (if config.programs.enableGpuTools then btop-cuda else null)
      ];
    };
  };

  inherit (builtins)
    mapAttrs
    attrValues
    concatMap
    filter
    ;
  inherit (lib) filterAttrs;

  makeEnableOptions = mapAttrs (
    _: value: {
      enable = lib.mkEnableOption value.description;
    }
  );

  enabledConfigurations = attrValues (
    filterAttrs (name: _: config.programs.${name}.enable or false) configurations
  );

  enabledPackages = filter (p: p != null) (concatMap (x: x.packages) enabledConfigurations);
in
{
  options.programs = makeEnableOptions configurations // {
    enableGpuTools = lib.mkEnableOption "GPU-accelerated variants of some tools (e.g. btop-cuda)";
  };

  config.environment.systemPackages = enabledPackages;
}
