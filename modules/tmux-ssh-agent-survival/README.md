# tmux-ssh-agent-survival

Keep SSH agent forwarding alive across `tmux` reattaches — and across any
long-lived, detached process — by pinning `SSH_AUTH_SOCK` to a stable symlink
that every new login re-points at the current live forwarded agent socket.

## The problem

When you `ssh -A` into a host, sshd creates a **fresh** agent socket for that
session (something like `/tmp/ssh-XXXX/agent.1234`) and sets `SSH_AUTH_SOCK` to
it. A `tmux` server — and every pane inside it — captures whatever
`SSH_AUTH_SOCK` was set when the server first started.

Detach, disconnect, reconnect from a **new** SSH session, `tmux attach`, and the
socket your panes are still pointing at is dead. The old `/tmp/ssh-XXXX/`
directory was cleaned up when the first session ended. Everything that needs the
agent now fails:

```
git push            # Permission denied (publickey)
ssh some-other-host # falls back to asking for a password
sudo -A / nested ssh # no key, no love
```

## The insight

Never let long-lived processes hold the ephemeral socket path. Give them a
**stable** path instead — `~/.ssh/agent.sock` — and make each new login
re-point that symlink at the current live socket.

- Long-lived processes (tmux panes, detached jobs) read the stable path
  **once** and keep working forever.
- Every fresh SSH login re-links the stable path to the new real socket, so
  agent forwarding "just works" after `tmux attach` from a new session — no
  per-prompt refresh, no wrapper.

## Traps this encodes (the load-bearing details)

1. **Only adopt a *live* forwarded socket.** A session that forwards no agent
   (Tailscale SSH, mosh, a plain `ssh` without `-A`) exports no
   `SSH_AUTH_SOCK`. Blindly re-linking there would clobber a perfectly good
   `agent.sock`. The hook only relinks when it sees a real socket that isn't
   already the stable path.

2. **`ssh-add -l` exit codes are the liveness oracle.** It exits `0` (keys
   present) *or* `1` (agent alive, no keys) when the socket is **live**, and
   `>1` only when the socket is dead. So "is my stable link stale?" is
   `exit > 1`, and "is this candidate socket usable?" is `exit <= 1`. Getting
   these thresholds backwards silently breaks self-healing.

3. **Wrap the probe in `timeout 1`.** A hung upstream SSH multiplexer /
   ControlMaster can make `ssh-add -l` block forever. Without the timeout that
   stalls *every* shell startup on the host.

4. **Self-heal from a candidate directory.** If the stable link is stale and the
   current session forwarded nothing, the hook walks newest-first sockets under
   `agentDir` (glob `s.*`) and relinks to the first live one it finds. The fish
   variant must glob into a variable first (`set -l __socks …; if set -q
   __socks[1]`) — unlike bash, a bare `for x in (ls -t …/s.*)` misbehaves in
   fish when nothing matches (it can end up listing the cwd instead of the empty
   set). `set` never errors on a no-match glob, so it's the safe gate.

5. **`~/.ssh/rc` covers non-interactive connections.** sshd runs `~/.ssh/rc` on
   **every** connection — including `git`, `rsync`, `scp` where no login shell
   ever starts — so the stable link is refreshed even then. Caveat: installing
   a `~/.ssh/rc` **disables sshd's built-in xauth handling**, so on X11
   forwarding hosts the rc has to replicate that xauth cookie line itself
   (`installXauth = true`).

6. **Absolute path to `timeout`.** The hooks use a fixed store path to
   `timeout` (not a bare `timeout`) so they work even where coreutils isn't on
   the default interactive PATH (e.g. macOS).

## Usage

This is a home-manager module. Import it and enable:

```nix
{
  imports = [ ./tmux-ssh-agent-survival ];

  programs.sshAgentSurvival = {
    enable = true;
    installFishHook = true;   # if you use fish; bash hook is on by default
    # installXauth  = true;   # only on X11Forwarding hosts
  };
}
```

Then make your clients use the stable path. In `~/.ssh/config`:

```
Host *
    IdentityAgent ~/.ssh/agent.sock
```

or export `SSH_AUTH_SOCK=$HOME/.ssh/agent.sock` from your login profile.

### Options

| Option            | Default               | Meaning                                                        |
| ----------------- | --------------------- | -------------------------------------------------------------- |
| `enable`          | `false`               | Turn the module on.                                            |
| `stableSocket`    | `$HOME/.ssh/agent.sock` | Stable path processes latch onto; point your clients here.   |
| `agentDir`        | `$HOME/.ssh/agent`    | Directory of candidate live sockets to self-heal from (`s.*`). |
| `installBashHook` | `true`                | Inject the hook into interactive bash startup.                 |
| `installFishHook` | `false`               | Inject the hook into interactive fish startup.                 |
| `installSshRc`    | `true`                | Install `~/.ssh/rc` to also refresh on non-interactive conns.  |
| `installXauth`    | `false`               | Replicate sshd's xauth handling in the rc (X11 hosts only).    |

## Notes / caveats

- **Not just for tmux.** The same mechanism rescues `screen`, `nohup`'d jobs,
  and any daemon started inside an SSH session — anything that outlives the
  connection that spawned it.
- **The `agentDir` self-heal is optional.** The direct `SSH_AUTH_SOCK` adoption
  path (trap #1) covers the common case on its own. `agentDir` only matters if
  something else in your setup drops candidate agent sockets there for the hook
  to fall back on.
- **Plain NixOS without home-manager:** port `initExtra` to
  `programs.bash.interactiveShellInit` (or `environment.interactiveShellInit`)
  and write the rc text to the user's `~/.ssh/rc` yourself. The shell logic is
  unchanged.
- **Agent forwarding is a trust decision.** Anyone with root on the remote host
  can use your forwarded agent for as long as you're connected. Prefer
  per-host `ForwardAgent` in `~/.ssh/config` over a blanket `ForwardAgent yes`.
## See also

- [tmux-ssh-agent-stable-sock](tmux-ssh-agent-stable-sock.md) — covers the same stable-symlink trick but uses the `programs.stableAgentSock` namespace, bundles an optional opinionated tmux config, and enables the fish hook by default alongside bash.
