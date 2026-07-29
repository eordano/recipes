# claude-code-session-mux

A registry plus WebSSH multiplexer for terminal sessions spread across many
hosts. Each host self-registers its live sessions with a small server; from one
browser page you see every running session and click to drop into a terminal on
the host it lives on — the server SSHes into that host and attaches its tmux
session, rendered by xterm.js in the browser.

It's built with Claude Code sessions running in `tmux` across many hosts in
mind, but the pattern is generic: any long-lived, per-host terminal process
you want to attach to from a single dashboard fits.

## The problem

When you run agents (or any interactive terminal job) on a dozen machines, there
is no single place to see what is running or to jump into one. You end up
`ssh`-ing around by hand, remembering which host has which session, and
re-attaching tmux by name. This module gives you one URL: a live list of every
session across all hosts, each a click away from a full terminal in the browser.

The moving parts:

- **A daemon** (a small Go server, supplied by you via the `package` option).
  It holds an in-memory registry of sessions and serves a dashboard plus a
  WebSocket-to-SSH bridge.
- **A registration client** on each host (a shell loop, not shipped here) that
  `POST`s a session when it starts, heartbeats it, and `DELETE`s it when the
  tmux session ends.

## The key insight — known_hosts is the security boundary

This is the trap worth internalizing before you deploy anything like this.

The bridge dials **a host named in caller-supplied JSON**. A host registers
itself by posting `{ "host": "...", "tmux_socket": "...", ... }`; when an
operator clicks that session, the server opens an SSH connection to whatever
address the registration claimed and forwards the operator's terminal into it.

If the SSH client trusts host keys on first use, a malicious (or compromised)
registrant can register a spoofed address and **redirect an operator's terminal
to a box the attacker controls** — capturing keystrokes, or presenting a fake
shell. So:

- The daemon dials with its own key (`sshKeyPath`) and validates the remote
  host key against a **pinned `known_hosts` file** (`knownHostsPath`).
- There is **no trust-on-first-use**. An unknown host key is a hard failure.
  That is exactly what you want for an unattended bridge that auto-routes to
  hosts named in untrusted input.

`knownHostsPath` is therefore the real access-control list of where the bridge
may ever send a terminal. Keep it in sync with the actual host keys of the
machines you bridge to (e.g. populate it with `ssh-keyscan`). A host missing
from it silently fails to open a terminal — which is the safe failure mode.

## Two SSH-bridge details worth remembering

If you write or adapt the bridge, these bit us and will bite you:

- **Constrain `HostKeyAlgorithms` from `known_hosts`.** Go's `crypto/ssh`
  defaults to offering every algorithm it supports, lets the server pick, then
  reports a "key mismatch" if the server's choice does not match the pinned
  entry. OpenSSH derives the offered algorithms from the `known_hosts` entries
  for the host being dialed; mirror that. Without it, a host recorded under
  ed25519 that *also* exposes an RSA key produces spurious mismatches.

- **Prepend `COLORTERM=truecolor TERM=xterm-256color` to the remote command.**
  Some sshd configs (notably macOS defaults) do not pass these via `AcceptEnv`,
  and inner TUIs render dim or wrong colors without them. xterm.js renders
  true-color escapes natively.

## Registration wire format

The registration client is not shipped with this recipe, but here is the
contract the server expects, so you can write one:

```
POST   /api/sessions                     # register a session (Bearer token)
PUT    /api/sessions/{slug}/heartbeat    # keep it alive (every ~30s)
DELETE /api/sessions/{slug}              # remove it when the session ends
GET    /api/sessions                     # read: dashboard data (no auth)
```

`POST` body (JSON):

```json
{
  "slug": "host-my-session",
  "host": "your-host",
  "user": "operator",
  "ssh_user": "operator",
  "tmux_socket": "/tmp/tmux-1000/default",
  "tmux_session": "my-session",
  "tmux_pane": "%0",
  "cwd": "/path/to/project",
  "source": "some-label"
}
```

Notes:

- **`tmux_socket` is the full socket path, not a `-L` short name.** The server
  runs `tmux -S "<tmux_socket>" attach-session …`, which works regardless of how
  the session was created. Resolve the path before posting:
  `tmux -L <name> display -p '#{socket_path}'`.
- **Auth is a write gate only.** `POST`/`PUT`/`DELETE` require
  `Authorization: Bearer <token>` (the `tokenFile` value). Read endpoints — the
  dashboard, the session page, the WebSocket — are unauthenticated. The real
  front gate is your reverse proxy (TLS, and a caller-IP allowlist if you want
  one). The token just keeps strangers from spraying the registry.
- **Lifecycle / GC.** The server expires an entry ~90s after its last heartbeat,
  so the client must heartbeat at least once a minute. On a clean exit the
  client sends a `DELETE` so the entry disappears immediately instead of
  lingering for the full timeout.

## How to use it

```nix
{
  imports = [ ./claude-code-session-mux ];

  modules.services.claude-code-mux = {
    enable = true;

    # You supply the daemon. This module does not vendor the binary.
    package = pkgs.claude-code-mux;

    # Bearer token that registrants present. Deliver out of band.
    tokenFile = "/run/secrets/claude-code-mux-token";

    # Key the bridge dials hosts with; its public half must be authorized
    # on every host that registers.
    sshKeyPath = "/var/lib/claude-code-mux/id_ed25519";

    # THE security boundary — pinned host keys of every bridgeable host.
    knownHostsPath = "/var/lib/claude-code-mux/known_hosts";

    # Defaults are usually fine:
    # addr = "127.0.0.1:17800";   # loopback; reverse-proxy it
    # dataDir = "/var/lib/claude-code-mux";
    # user = "claude-code-mux";
    # group = "claude-code-mux";
  };
}
```

Then reverse-proxy `addr` behind nginx (or similar) with TLS. Generate the
daemon's SSH key and initialize an (initially empty) `known_hosts` at
`dataDir`, then populate it with the host keys you intend to bridge to.

## Caveats

- **You must provide `package`.** The Go daemon source is not part of this
  recipe; wire in your own `buildGoModule` derivation that produces
  `bin/claude-code-mux` honoring the flags in `default.nix`.
- **Never expose `addr` directly.** Read endpoints are unauthenticated by
  design; the reverse proxy is your front door.
- **The registration client is yours to write.** See the wire format above.
- The daemon runs as an unprivileged system user with `ProtectSystem=strict`
  and a private `StateDirectory`; the SSH key and `known_hosts` live under
  `dataDir` (mode `0700`).
