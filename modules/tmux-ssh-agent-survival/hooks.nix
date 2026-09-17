{
  pkgs,
  lib,
  sock ? "$HOME/.ssh/agent.sock",
  dir ? "$HOME/.ssh/agent",
  installXauth ? false,
}:
let
  timeout = "${pkgs.coreutils}/bin/timeout";
in
{
  bashSshHook = ''
    if [ -n "$SSH_AUTH_SOCK" ] && [ "$SSH_AUTH_SOCK" != "${sock}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
      ln -sf "$SSH_AUTH_SOCK" "${sock}"
    fi
    if [ -L "${sock}" ]; then
      SSH_AUTH_SOCK="${sock}" ${timeout} 1 ssh-add -l >/dev/null 2>&1
      if [ $? -gt 1 ]; then
        for __s in $(command ls -t ${dir}/s.* 2>/dev/null); do
          SSH_AUTH_SOCK="$__s" ${timeout} 1 ssh-add -l >/dev/null 2>&1
          if [ $? -le 1 ]; then
            ln -sf "$__s" "${sock}"
            break
          fi
        done
        unset __s
      fi
      export SSH_AUTH_SOCK="${sock}"
    fi
  '';

  fishSshHook = ''
    if test -n "$SSH_AUTH_SOCK"; and test "$SSH_AUTH_SOCK" != "${sock}"; and test -S "$SSH_AUTH_SOCK"
        ln -sf "$SSH_AUTH_SOCK" "${sock}"
    end
    if test -L "${sock}"
        env SSH_AUTH_SOCK=${sock} ${timeout} 1 ssh-add -l >/dev/null 2>&1
        if test $status -gt 1
            set -l __socks ${dir}/s.*
            if set -q __socks[1]
                for __s in (command ls -t $__socks 2>/dev/null)
                    env SSH_AUTH_SOCK=$__s ${timeout} 1 ssh-add -l >/dev/null 2>&1
                    if test $status -le 1
                        ln -sf $__s "${sock}"
                        break
                    end
                end
            end
        end
        set -gx SSH_AUTH_SOCK "${sock}"
    end
  '';

  sshRc = ''
    if [ -n "$SSH_AUTH_SOCK" ] && [ -S "$SSH_AUTH_SOCK" ] \
       && [ "$SSH_AUTH_SOCK" != "${sock}" ]; then
      ln -sf "$SSH_AUTH_SOCK" "${sock}"
    fi
  ''
  + lib.optionalString installXauth ''
    if read proto cookie && [ -n "$DISPLAY" ]; then
      echo add "unix:$(echo "$DISPLAY" | cut -c11-)" "$proto" "$cookie" | xauth -q - 2>/dev/null || true
    fi
  '';
}
