# NixOS module: turn named package bundles into per-host enable toggles.
#
# Each bundle carries a human-readable `description` that does double duty:
# it is the text of the bundle's `mkEnableOption`. So a host writes
#
#   programs.develop.enable = true;
#   programs.sysadmin-tools.enable = true;
#
# and gets exactly those package sets in environment.systemPackages.
#
# Two patterns worth stealing from this file:
#
#   * `linuxOnly`  — wrap packages that only build / make sense on Linux so a
#                    shared bundle can be imported unchanged on Darwin (macOS)
#                    hosts, silently dropping the incompatible entries instead
#                    of failing the whole evaluation.
#
#   * null filter  — a bundle entry may evaluate to `null` (e.g. a GPU-only
#                    package gated on a host option). The final list is
#                    filtered so those nulls never reach systemPackages, which
#                    lets you write `if cond then pkg else null` inline.
#
# This is a drop-in module. Import it and flip the `programs.<bundle>.enable`
# booleans per host. Edit the `configurations` set below to taste — the bundle
# contents here are only illustrative.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (pkgs.stdenv) isLinux;

  # Drop a package list entirely on non-Linux hosts. On Linux it is the
  # identity; on Darwin it evaluates to `[]`, so a bundle shared across a
  # cross-platform fleet stays importable everywhere.
  #
  # Use it for packages that either don't build on Darwin or are meaningless
  # there. Two real-world examples of *why* you reach for this:
  #
  #   * `cargo-watch` is archived upstream and won't build on aarch64-darwin
  #     under recent nixpkgs (Cocoa module-cache issues in the sandbox); prefer
  #     a cross-platform equivalent like `bacon`.
  #   * `sshfs`'s Nix build links libfuse3 and can't drive macOS FUSE; on Darwin
  #     you install a fuse-t-based sshfs out of band instead.
  linuxOnly = ps: if isLinux then ps else [ ];

  # ---------------------------------------------------------------------------
  # The bundles. `description` is REQUIRED and becomes the mkEnableOption text.
  # `packages` is the list pulled into systemPackages when the bundle is on.
  # Contents below are generic examples — replace with your own.
  # ---------------------------------------------------------------------------
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
      # Some packages are unavailable / broken on a given system; guard with
      # the same platform-predicate style you'd use anywhere.
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
        # Archived upstream + Darwin build breakage — see `linuxOnly` note.
        cargo-watch
        # libfuse3-linked; Darwin needs a fuse-t build instead.
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
        # Bundle entry that may resolve to `null`, gated on a host option.
        # The `null` is stripped by the filter below, so this inline
        # conditional is safe. Flip `programs.enableGpuTools` per host.
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

  # description -> `{ enable = mkEnableOption ...; }`, one nested option per
  # bundle. The nesting is what makes the documented `programs.<bundle>.enable`
  # interface work: a bare `mkEnableOption` would declare `programs.<bundle>`
  # itself as the boolean, and setting `programs.<bundle>.enable = true` on that
  # is a type error ("not of type boolean").
  makeEnableOptions = mapAttrs (_: value: {
    enable = lib.mkEnableOption value.description;
  });

  # The bundles whose enable flag is set for this host.
  enabledConfigurations = attrValues (
    filterAttrs (name: _: config.programs.${name}.enable or false) configurations
  );

  # Flatten to a package list, dropping any `null` entries (see the null-filter
  # note above). Without this filter, a gated-off package would crash eval.
  enabledPackages = filter (p: p != null) (concatMap (x: x.packages) enabledConfigurations);
in
{
  options.programs = makeEnableOptions configurations // {
    # Extra host toggle used by the `null`-gated example above. Declared
    # outside the generated set so it isn't itself a package bundle.
    enableGpuTools = lib.mkEnableOption "GPU-accelerated variants of some tools (e.g. btop-cuda)";
  };

  config.environment.systemPackages = enabledPackages;
}
