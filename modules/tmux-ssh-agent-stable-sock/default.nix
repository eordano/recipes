{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.stableAgentSock;

  timeout = "${pkgs.coreutils}/bin/timeout";

  inherit (cfg) stableSock;

  candidateGlob = cfg.candidateSocketGlob;

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

  sshRc = ''
    if [ -n "$SSH_AUTH_SOCK" ] && [ -S "$SSH_AUTH_SOCK" ] \
       && [ "$SSH_AUTH_SOCK" != "${stableSock}" ]; then
      ln -sf "$SSH_AUTH_SOCK" "${stableSock}"
    fi
    if read proto cookie && [ -n "$DISPLAY" ]; then
      echo add "unix:$(echo "$DISPLAY" | cut -c11-)" "$proto" "$cookie" | xauth -q - 2>/dev/null || true
    fi
  '';

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

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
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
    ]
  );
}
