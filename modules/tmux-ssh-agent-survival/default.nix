{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.sshAgentSurvival;

  hooks = import ./hooks.nix {
    inherit pkgs lib;
    sock = cfg.stableSocket;
    dir = cfg.agentDir;
    inherit (cfg) installXauth;
  };
  inherit (hooks) bashSshHook fishSshHook sshRc;
in
{
  options.programs.sshAgentSurvival = {
    enable = lib.mkEnableOption "SSH agent socket survival across tmux reattach";

    stableSocket = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/.ssh/agent.sock";
      description = ''
        Stable socket path that long-lived processes latch onto. Point your
        clients at this (e.g. `SSH_AUTH_SOCK`, or an `IdentityAgent` line in
        ~/.ssh/config). Shell-expanded at runtime, so `$HOME` is fine.
      '';
    };

    agentDir = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/.ssh/agent";
      description = ''
        Directory scanned (newest-first, glob `s.*`) for live candidate sockets
        when the stable link goes stale. Populate it however your setup drops
        forwarded/agent sockets (e.g. a `Match` block or a launcher symlinking
        each new agent socket here). Leave as the default if you only rely on
        the direct SSH_AUTH_SOCK adoption path.
      '';
    };

    installBashHook = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Inject the hook into interactive bash startup.";
    };

    installFishHook = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Inject the hook into interactive fish startup.";
    };

    installSshRc = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install ~/.ssh/rc so the stable link is also refreshed on
        non-interactive connections (git/rsync/scp), not just login shells.
      '';
    };

    installXauth = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Replicate sshd's built-in xauth handling inside ~/.ssh/rc. Enable only
        on hosts with X11Forwarding, since installing an rc file disables
        sshd's own xauth cookie injection.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs.bash.initExtra = lib.mkIf cfg.installBashHook bashSshHook;
    programs.fish.interactiveShellInit = lib.mkIf cfg.installFishHook fishSshHook;
    home.file.".ssh/rc" = lib.mkIf cfg.installSshRc { text = sshRc; };
  };
}
