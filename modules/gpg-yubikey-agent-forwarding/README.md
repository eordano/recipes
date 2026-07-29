# gpg-yubikey-agent-forwarding

A NixOS module that configures a hardened GnuPG agent (tuned for a YubiKey /
smartcard) **and** makes a host able to *receive* a `gpg-agent` forwarded to it
over SSH — so the key material never leaves the machine the YubiKey is plugged
into.

## The problem

You keep your signing/decryption key on a YubiKey plugged into your laptop. You
want a shell on a remote server (a build box, a workstation you SSH into) to be
able to sign commits or decrypt secrets using that key — **without** copying the
private key anywhere. SSH can forward the `gpg-agent` socket, but making the
*receiving* host accept the forward reliably is where people get stuck.

## The key insight / trap

Two things must be true on the host that receives the forwarded agent, and
neither is obvious:

1. **The receiving host must not run its own gpg-agent.** A locally started
   agent creates/owns the socket path and *shadows* the tunneled one — gpg on
   the remote host silently talks to the wrong (local, keyless) agent. This
   module forces `enableAgent` and `enableSSHSupport` off whenever
   `receiveForwardedAgent = true`.

2. **The runtime directory must exist, mode 0700, before the forward binds.**
   SSH's `RemoteForward` binds the socket path (`/run/user/<uid>/gnupg/S.gpg-agent`)
   at connection time — which is *before* your login shell would normally create
   `/run/user/<uid>/gnupg`. If the directory is missing, or exists with loose
   permissions, the forward **fails silently**: no error, the socket just isn't
   there. A oneshot systemd *user* service (`gpg-forward-dir`) pre-creates the
   directory with mode 0700 so the bind always has a home.

A third, related detail lives on the SSH layer rather than in this module: the
socket-pair string. `forwardRemoteOption` is a **read-only** option that
publishes the exact `RemoteForward` value the *sender* must use. It is read-only
on purpose — the sender's SSH config and this module must agree on the exact
socket paths, so you read the string from here instead of hand-copying it and
letting the two drift out of sync.

## Usage

On the **receiving** host:

```nix
{
  imports = [ ./gpg-yubikey-agent-forwarding ];

  modules.gpg = {
    enable = true;
    uid = 1000;                 # must match the receiving user's real uid
    receiveForwardedAgent = true;
  };
}
```

On the **sending** host (the one with the YubiKey), point SSH at the read-only
socket-pair string so the two never drift:

```nix
programs.ssh.extraConfig = ''
  Host your-host
    RemoteForward ${nodes.your-host.config.modules.gpg.forwardRemoteOption}
'';
```

Plain `~/.ssh/config` equivalent (the value `forwardRemoteOption` computes for
uid 1000):

```
Host your-host
    RemoteForward /run/user/1000/gnupg/S.gpg-agent /run/user/1000/gnupg/S.gpg-agent.extra
```

On a normal host that just wants a hardened local agent (no forwarding):

```nix
modules.gpg = {
  enable = true;
  pinentryPackage = pkgs.pinentry-qt;   # graphical desktop; use pinentry-curses headless
  configureHomeManager = true;          # requires the Home Manager NixOS module
  user = "alice";
  publicKeys = [ { source = ./keys/yubikey.asc; trust = 5; } ];
};
```

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `user` | `"youruser"` | Login user whose Home Manager gpg config is written. |
| `uid` | `1000` | Numeric uid used to build the `/run/user/<uid>/gnupg` socket paths. Must match the real uid. |
| `receiveForwardedAgent` | `false` | This host receives a forwarded agent: disables the local agent + SSH support, enables the dir-precreate service. |
| `enableAgent` | `true` | Run a local gpg-agent (auto-forced off when receiving a forward). |
| `enableSSHSupport` | `true` | Use gpg-agent as the SSH agent (auto-forced off when receiving a forward). |
| `pinentryPackage` | `pkgs.pinentry-curses` | pinentry used for PIN prompts. Graphical on desktops, curses headless. |
| `keyId` | `null` | Optional key id exported as the `KEYID` env var for scripts. |
| `publicKeys` | `[]` | Public keys to import + trust (Home Manager). Point `source` at your own `.asc`. |
| `configureHomeManager` | `false` | Also write a hardened `programs.gpg` config via Home Manager. |
| `forwardRemoteOption` | *(read-only)* | The `RemoteForward` value the sender must use; derived from `uid`. |

## What "hardened" means here

The agent runs with short cache TTLs (`default-cache-ttl = 60`,
`max-cache-ttl = 120`) so the PIN is re-requested frequently. The Home Manager
`gpg.conf` enforces strong cipher/digest preferences (AES256, SHA512),
`throw-keyids` (recipients aren't leaked in encrypted output),
`require-cross-certification`, `no-symkey-cache`, and friends. `disable-ccid`
routes smartcard access around flaky CCID drivers that many YubiKeys trip over.

## Caveats

- **`uid` must be correct.** The socket paths are built from it; a wrong uid
  puts the forwarded socket in a directory nothing reads.
- **sshd on the receiver:** set `StreamLocalBindUnlink yes` in `sshd_config`
  so a stale forwarded socket is unlinked and re-bound on reconnect — otherwise
  the sender's `RemoteForward` fails with *"address already in use"* after a
  dropped connection. (NixOS: `services.openssh.extraConfig` or
  `settings.StreamLocalBindUnlink = "yes";`.)
- **`configureHomeManager` needs the Home Manager NixOS module imported.** With
  it off, this module only manages the system agent; bring your own `gpg.conf`.
- The forwarding path assumes a systemd-logind runtime dir (`/run/user/<uid>`).
- A forwarded agent only exposes what the physical card can do — the private key
  never traverses the tunnel, only signing/decryption *requests* do.
