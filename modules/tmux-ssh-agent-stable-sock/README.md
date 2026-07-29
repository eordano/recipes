# tmux-ssh-agent-stable-sock

Keep SSH agent forwarding alive inside long-lived tmux panes by pinning
`$SSH_AUTH_SOCK` to one stable symlink that each new login re-points at the
current live forwarded socket.

## The problem

Every fresh `ssh -A` connection into a box creates a **new, randomly named**
agent-forwarding socket (something like `~/.ssh/agent/s.12345`). `sshd` sets
`SSH_AUTH_SOCK` to that path for the session it started.

A tmux pane is longer-lived than any one SSH connection. It captured whatever
`SSH_AUTH_SOCK` was set when the pane's shell first started, and it keeps that
value forever. So:

1. You `ssh -A` in, `tmux attach`, work for a while, disconnect.
2. The forwarded socket from that connection is torn down.
3. You `ssh -A` in again (new socket path), `tmux attach`.
4. Inside your still-running panes, `SSH_AUTH_SOCK` still points at the **old,
   now-dead** socket. `git push`, `ssh`, `ssh-add -l` all fail: *"Could not
   open a connection to your authentication agent."*

## The fix

Introduce a level of indirection: one **stable** path (default
`~/.ssh/agent.sock`) that is always a symlink to the current live forwarded
socket.

- Long-lived processes (tmux panes, detached jobs) export `SSH_AUTH_SOCK`
  pointing at the **stable** path and capture that once.
- Every new login re-points the symlink at the fresh forwarded socket.
- Result: agent forwarding "just works" after `tmux attach` from a new SSH
  session, with no per-prompt refresh and no re-attaching panes.

This is installed three ways so the link is fresh no matter how you arrive:

- **bash** interactive-shell init (`bashSshHook`)
- **fish** interactive-shell init (`fishSshHook`)
- **`~/.ssh/rc`** (`sshRc`), which `sshd` runs on *every* connection —
  including non-interactive ones where no login shell ever starts.

## The traps it defends against (the interesting part)

**1. Don't clobber a working link with an agent-less session.**
A session with no forwarded agent at all (for example a Tailscale-SSH session,
or a plain `ssh` without `-A`) exports an empty or non-socket `SSH_AUTH_SOCK`.
Blindly relinking on every login would point your stable link at nothing and
break the panes that were working. The hook only adopts the incoming socket
when it is a real socket (`-S`) **and** is not already the stable link.

**2. Read `ssh-add -l` exit codes correctly — the socket, not the keys.**
`ssh-add -l` exits:

| exit | meaning                          |
|------|----------------------------------|
| 0    | socket live, agent has keys      |
| 1    | socket live, agent has **no** keys |
| >1   | socket **dead** / unreachable    |

The liveness test is therefore **`exit > 1 == dead`**, *not* "exit != 0".
Testing for non-zero would wrongly declare a perfectly good agent-with-no-keys
socket dead and start thrashing the link. When the stable link is found dead,
the hook self-heals: it scans candidate forwarded sockets newest-first and
relinks to the first live one.

**3. A hung mux must never stall shell startup.**
If there is a broken or hung SSH multiplexer to a remote host, `ssh-add -l`
against a dead socket can block. The probe is wrapped in `timeout 1`, so a hung
socket costs at most a second and shell startup never hangs.

**4. Use a fixed `timeout` store path.**
The hooks call `${pkgs.coreutils}/bin/timeout`, not a bare `timeout`, so they
work even on hosts (e.g. macOS) where coreutils is not on the default
interactive PATH.

## Usage (Home Manager)

```nix
{
  imports = [ ./modules/tmux-ssh-agent-stable-sock ];

  programs.stableAgentSock.enable = true;

  # Optional: also install the bundled opinionated tmux config
  # (Nord theme + logging plugin, vi keys, dual C-a/C-b prefix,
  #  vim-style pane navigation, mouse, base-index 1).
  # programs.stableAgentSock.tmux.enable = true;
}
```

### Options

| option | default | purpose |
|--------|---------|---------|
| `programs.stableAgentSock.enable` | `false` | Turn the module on. |
| `stableSock` | `"$HOME/.ssh/agent.sock"` | Shell expr for the stable symlink path processes pin to. |
| `candidateSocketGlob` | `"$HOME/.ssh/agent/s.*"` | Glob of ephemeral forwarded sockets to scan when self-healing. Point at wherever your forwarded sockets land. |
| `installShellHooks` | `true` | Install the bash + fish interactive-shell hooks. |
| `installSshRc` | `true` | Install `~/.ssh/rc` (refreshes the link on every sshd connection). |
| `tmux.enable` | `false` | Also install the bundled opinionated tmux config. |
| `tmux.setFishDefaultShell` | `false` | Set tmux `default-shell` to fish. |

## Where do the forwarded sockets land?

`candidateSocketGlob` must match the ephemeral sockets `sshd` creates for
forwarded agents. If you use OpenSSH's default forwarding, look for them under
a per-user temp directory and set the glob accordingly. Many setups
deterministically place them by configuring `StreamLocalBindPath` (or an agent
proxy) so they all live under one directory like `~/.ssh/agent/` — which is
what the default glob assumes. Adjust to your layout.

## Caveats

- **Home Manager module.** If you don't use Home Manager, lift `bashSshHook` /
  `fishSshHook` / `sshRc` from the `let` block in `default.nix` into your own
  shell rc and `~/.ssh/rc` by hand — the shell logic is the reusable core.
- **`~/.ssh/rc` suppresses sshd's built-in xauth handling.** Installing any
  `~/.ssh/rc` disables sshd's automatic `xauth` cookie handling, so `sshRc`
  re-implements it. If you enable X11 forwarding and rely on it, keep that
  block; if you don't forward X11 it's a harmless no-op.
- The tmux config is a personal keymap included for convenience. It is entirely
  optional (`tmux.enable`) and orthogonal to the agent-socket logic.
## See also

- [tmux-ssh-agent-survival](tmux-ssh-agent-survival.md) — covers the same stable-symlink trick but uses a different Home Manager option namespace (`programs.sshAgentSurvival`), adds an explicit `installXauth` flag for X11-forwarding hosts, and does not bundle a tmux config.
