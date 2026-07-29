# home-manager-alias-namespace
#
# Exposes a thin top-level `home.*` namespace (file / activation / env /
# programs / services) that `mkAliasDefinitions` forwards into one or more
# Home Manager users. Any other NixOS module can then write
#
#     home.file.".config/foo".text = "...";
#
# without knowing which user owns the Home Manager config or how it is wired.
# Also ships an optional nightly `nix-index` rebuild (so `nix-locate` /
# command-not-found stays fresh) at idle IO priority, and an optional XDG
# user-dirs redirect that tucks the standard dirs under an archive/ subtree.
#
# Drop it into your imports and set `enable-home-manager = true;`. Requires the
# home-manager NixOS module to be imported elsewhere in your configuration.
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.enable-home-manager;
  hm = config.home-manager-alias;

  mkOpt' =
    type: default: description:
    lib.mkOption { inherit type default description; };

  # XDG user-dirs pointed at an archive/ subtree so $HOME itself stays tidy.
  # The unusual bits: `user-dirs.conf` with enabled=False stops the
  # xdg-user-dirs-update daemon from rewriting these paths at login, and
  # createDirectories=false avoids materialising empty dirs you never use.
  xdgConfig = {
    enable = true;
    configFile."user-dirs.conf".text = "enabled=False\n";
    userDirs = {
      enable = true;
      createDirectories = false;
      setSessionVariables = true;
      desktop = "${hm.xdg.archiveRoot}/desktop";
      download = "${hm.xdg.archiveRoot}/downloads";
      documents = "$HOME";
      music = "$HOME";
      pictures = "${hm.xdg.archiveRoot}/pictures";
      publicShare = "$HOME/.public";
      templates = "$HOME";
      videos = "${hm.xdg.archiveRoot}/videos";
    };
  };

  # Per-user Home Manager config. Every user in `home-manager-alias.users`
  # receives the SAME aliased definitions, so a single `home.file.…` set by
  # any module lands in all of them. mkAliasDefinitions is the load-bearing
  # trick: it forwards the *definitions* (not the merged value) of the
  # top-level option into the HM option, preserving priorities / mkForce /
  # mkIf from the contributing modules.
  mkUser = _name: lib.mkMerge [
    {
      home = {
        inherit (config.system) stateVersion;
        enableNixpkgsReleaseCheck = false;
        file = lib.mkAliasDefinitions options.home.file;
        activation = lib.mkAliasDefinitions options.home.activation;
        sessionVariables = lib.mkAliasDefinitions options.home.env;
      };
      programs = (lib.mkAliasDefinitions options.home.programs) // {
        man.generateCaches = false;
        ssh.enableDefaultConfig = false;
      };
      services = (lib.mkAliasDefinitions options.home.services) // lib.optionalAttrs hm.enableLorri {
        lorri.enable = true;
      };
    }
    (lib.mkIf hm.xdg.enable { xdg = xdgConfig; })
  ];
in
{
  options = {
    enable-home-manager = lib.mkEnableOption "the top-level home.* alias namespace";

    # The public namespace other modules contribute to. Kept deliberately
    # loose (attrs) so any module can add to it without importing this file.
    home = {
      programs = lib.mkOption {
        description = "Home Manager programs.* (contributed by other modules).";
        default = { };
      };
      services = lib.mkOption {
        description = "Home Manager services.* (contributed by other modules).";
        default = { };
      };
      file = mkOpt' lib.types.attrs { } "Files to place directly in $HOME.";
      activation = mkOpt' lib.types.attrs { } "Activation scripts to run on home-manager switch.";
      env = mkOpt' lib.types.attrs { } "Environment variables to set on shells (aliased to home.sessionVariables).";
    };

    home-manager-alias = {
      users = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "user" ];
        example = [ "alice" "bob" ];
        description = ''
          Users whose Home Manager config receives the aliased home.*
          namespace. Every listed user gets the same definitions.
        '';
      };

      enableLorri = lib.mkEnableOption "the lorri services.lorri.enable for each user";

      xdg = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Redirect XDG user-dirs into an archive/ subtree.";
        };
        archiveRoot = lib.mkOption {
          type = lib.types.str;
          default = "$HOME/archive";
          description = "Base directory the archived XDG dirs live under.";
        };
      };

      # Extra Home Manager modules shared across all managed users, e.g. a
      # theming module. Left empty by default so this recipe carries no
      # opinion about your desktop.
      sharedModules = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [ ];
        description = "Home Manager modules applied to every managed user.";
      };

      nixIndex = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Install a nightly nix-index rebuild timer.";
        };
        user = lib.mkOption {
          type = lib.types.str;
          default = lib.head hm.users;
          defaultText = lib.literalExpression "builtins.head config.home-manager-alias.users";
          description = "User the nix-index rebuild runs as (its ~/.cache is written).";
        };
        home = lib.mkOption {
          type = lib.types.str;
          default = "/home/${hm.nixIndex.user}";
          defaultText = lib.literalExpression ''"/home/''${config.home-manager-alias.nixIndex.user}"'';
          description = "HOME for the rebuild service (nix-index writes ~/.cache/nix-index there).";
        };
        nixPath = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos";
          description = "Optional NIX_PATH override for the rebuild (null = inherit system default).";
        };
      };
    };
  };

  config = lib.mkIf cfg {
    # Nightly nix-index rebuild. Runs at Nice 19 / idle IO so it never
    # competes with foreground work; Persistent + RandomizedDelaySec means a
    # box that was asleep at the scheduled time still catches up (jittered so
    # a fleet doesn't stampede). Needs network for the store metadata fetch.
    systemd.services.nix-index-update = lib.mkIf hm.nixIndex.enable {
      description = "Rebuild the nix-index files database (nix-locate / command-not-found)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [
        config.nix.package
        pkgs.nix-index
      ];
      environment = {
        HOME = hm.nixIndex.home;
      } // lib.optionalAttrs (hm.nixIndex.nixPath != null) {
        NIX_PATH = hm.nixIndex.nixPath;
      };
      serviceConfig = {
        Type = "oneshot";
        User = hm.nixIndex.user;
        ExecStart = "${pkgs.nix-index}/bin/nix-index";
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers.nix-index-update = lib.mkIf hm.nixIndex.enable {
      description = "Nightly rebuild of the nix-index files database";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "30m";
        Unit = "nix-index-update.service";
      };
    };

    home-manager = {
      backupFileExtension = ".bak";
      useGlobalPkgs = true;
      useUserPackages = true;
      sharedModules = hm.sharedModules;
      users = lib.genAttrs hm.users mkUser;
    };
  };
}
