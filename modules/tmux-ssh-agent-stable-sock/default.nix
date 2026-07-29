# tmux-ssh-agent-stable-sock
#
# Home Manager module. Keeps SSH agent forwarding working inside long-lived
# tmux panes (and any detached process) by pinning $SSH_AUTH_SOCK to a stable
# symlink that each new login re-points to the current live forwarded socket.
#
# The trap it solves: every fresh `ssh -A` connection gets a NEW random
# forwarded socket path (e.g. ~/.ssh/agent/s.12345). A tmux pane started under
# an old connection captured the OLD path once and never sees the new one, so
# `git push` / `ssh` inside a re-attached pane fail with "no agent". Pinning
# SSH_AUTH_SOCK to one stable path — and re-pointing that symlink on each login —
# means long-lived processes read the stable path and always reach a live agent.
#
# Import into a Home Manager configuration and set:
#   programs.stableAgentSock.enable = true;
#
# Non-Home-Manager users: lift `bashSshHook` / `fishSshHook` / `sshRc` from the
# `let` block below into your own shell rc and ~/.ssh/rc by hand.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.stableAgentSock;

  # A fixed store path is used instead of a bare `timeout` so the hooks work
  # even on hosts (e.g. macOS) where coreutils is not on the default PATH.
  timeout = "${pkgs.coreutils}/bin/timeout";

  # Shell expression (evaluated at runtime) for the stable symlink path that
  # SSH_AUTH_SOCK is pinned to. Long-lived processes capture THIS, never the
  # ephemeral forwarded socket.
  stableSock = cfg.stableSock;

  # Glob (evaluated at runtime) matching the ephemeral forwarded sockets that a
  # fresh login might have dropped. Used to self-heal a stale link by picking
  # the newest live socket. OpenSSH places forwarded sockets under a per-user
  # directory; adjust to wherever yours land.
  candidateGlob = cfg.candidateSocketGlob;

  # --- The load-bearing bit -------------------------------------------------
  #
  # Liveness is probed with `ssh-add -l`, which exits:
  #   0  socket live, keys present
  #   1  socket live, agent has no keys
  #   >1 socket DEAD (no agent / broken)
  # so the test is `exit > 1 == dead`. The probe is wrapped in `timeout 1` so a
  # hung ssh mux to a remote host can never stall shell startup.
  #
  # Ordering / safety invariants encoded below:
  #   1. Only adopt the incoming SSH_AUTH_SOCK if it is a real, live socket AND
  #      is not already the stable link — a Tailscale-SSH (or any agent-less)
  #      session exports no agent, and blindly re-linking would clobber a
  #      working agent.sock.
  #   2. If the stable link is now dead, self-heal by scanning candidate
  #      sockets newest-first and relinking to the first live one.
  #   3. Finally export SSH_AUTH_SOCK to the stable path unconditionally, so
  #      every child process reads the stable indirection.

  bashSshHook = ''
    if [ -n "$SSH_AUTH_SOCK" ] && [ "$SSH_AUTH_SOCK" != "${stableSock}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
      ln -sf "$SSH_AUTH_SOCK" "${stableSock}"
    fi
    if [ -L "${stableSock}" ]; then
      SSH_AUTH_SOCK="${stableSock}" ${timeout} 1 ssh-add -l >/dev/null 2>&1
      if [ $? -gt 1 ]; then
        for __s in $(command ls -t ${candidateGlob} 2>/dev/null); do
          SSH_AUTH_SOCK="$__s" ${timeout} 1 ssh-add -l >/dev/null 2>&1
          if [ $? -le 1 ]; then
            ln -sf "$__s" "${stableSock}"
            break
          fi
        done
        unset __s
      fi
      export SSH_AUTH_SOCK="${stableSock}"
    fi
  '';

  fishSshHook = ''
    if test -n "$SSH_AUTH_SOCK"; and test "$SSH_AUTH_SOCK" != "${stableSock}"; and test -S "$SSH_AUTH_SOCK"
        ln -sf "$SSH_AUTH_SOCK" "${stableSock}"
    end
    if test -L "${stableSock}"
        env SSH_AUTH_SOCK=${stableSock} ${timeout} 1 ssh-add -l >/dev/null 2>&1
        if test $status -gt 1
            set -l __socks ${candidateGlob}
            if set -q __socks[1]
                for __s in (command ls -t $__socks 2>/dev/null)
                    env SSH_AUTH_SOCK=$__s ${timeout} 1 ssh-add -l >/dev/null 2>&1
                    if test $status -le 1
                        ln -sf $__s "${stableSock}"
                        break
                    end
                end
            end
        end
        set -gx SSH_AUTH_SOCK "${stableSock}"
    end
  '';

  # ~/.ssh/rc runs on EVERY sshd connection (non-interactive included), so the
  # stable link is refreshed even when no login shell ever starts. Note:
  # installing an rc suppresses sshd's built-in xauth handling, so this
  # replicates that xauth logic for hosts with X11Forwarding enabled.
  sshRc = ''
    if [ -n "$SSH_AUTH_SOCK" ] && [ -S "$SSH_AUTH_SOCK" ] \
       && [ "$SSH_AUTH_SOCK" != "${stableSock}" ]; then
      ln -sf "$SSH_AUTH_SOCK" "${stableSock}"
    fi
    if read proto cookie && [ -n "$DISPLAY" ]; then
      echo add "unix:$(echo "$DISPLAY" | cut -c11-)" "$proto" "$cookie" | xauth -q - 2>/dev/null || true
    fi
  '';

  # --- Optional tmux config -------------------------------------------------
  # clock24 MUST be applied before the Nord plugin loads, since Nord reads
  # clock-mode-style at load time.
  tmuxExtraConfig =
    builtins.readFile ./config/tmux.conf
    + ''
      run-shell ${pkgs.tmuxPlugins.logging}/share/tmux-plugins/logging/logging.tmux
    ''
    + lib.optionalString cfg.tmux.setFishDefaultShell ''
      set -g default-shell ${pkgs.fish}/bin/fish
    '';
in
{
  options.programs.stableAgentSock = {
    enable = lib.mkEnableOption "stable SSH_AUTH_SOCK indirection for long-lived tmux panes";

    stableSock = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/.ssh/agent.sock";
      description = ''
        Shell expression for the stable symlink path that SSH_AUTH_SOCK is
        pinned to. Long-lived processes capture this path, and each new login
        re-points it at the current live forwarded socket.
      '';
    };

    candidateSocketGlob = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/.ssh/agent/s.*";
      description = ''
        Shell glob matching ephemeral forwarded agent sockets, used to
        self-heal a stale link by adopting the newest live socket. Point this
        wherever your forwarded sockets land (see StreamLocalBindPath / your
        agent-forwarding setup).
      '';
    };

    installShellHooks = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install the bash and fish interactive-shell hooks that maintain the stable link.";
    };

    installSshRc = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install ~/.ssh/rc so the link is refreshed on every sshd connection, even non-interactive ones.";
    };

    tmux = {
      enable = lib.mkEnableOption "an opinionated tmux config (Nord theme, logging, vi keys, dual C-a/C-b prefix)";

      setFishDefaultShell = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Set tmux default-shell to fish.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (lib.mkIf cfg.installShellHooks {
      programs.bash.initExtra = bashSshHook;
      programs.fish.interactiveShellInit = fishSshHook;
    })

    (lib.mkIf cfg.installSshRc {
      home.file.".ssh/rc".text = sshRc;
    })

    (lib.mkIf cfg.tmux.enable {
      programs.tmux = {
        enable = true;
        clock24 = true;
        plugins = with pkgs.tmuxPlugins; [
          nord
          logging
        ];
        extraConfig = tmuxExtraConfig;
      };
    })
  ]);
}
