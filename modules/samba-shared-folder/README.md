# samba-shared-folder

A single declarative Samba (SMB) share for a NixOS host — with the one thing
NixOS *can't* declare, SMB passwords, bridged in via a guarded oneshot service.

## The problem

NixOS can declare a Samba share end to end: the share path, permissions,
firewall, `valid users`, everything. But there is **no declarative way to set
an SMB password.** `smbpasswd` writes to an on-disk password database (a tdb)
at runtime; there is no `services.samba.users.<name>.password` option. So a
share you declare purely in Nix is unusable until someone SSHes in and runs
`smbpasswd` by hand.

This module closes that gap by running `smbpasswd` for you from a secret file,
idempotently, on every activation.

## The two traps

Reading the Nix won't tell you either of these:

1. **SMB users must already exist as system users.** This module creates only
   the *group*, never the accounts. The password-setup service silently skips
   any `smbUser` with no matching `id`, so a missing system account does not
   fail the build — it surfaces later as an **authentication failure** at
   connect time. Make sure every name in `smbUsers` also has a
   `users.users.<name>` somewhere in the host config.

2. **Rotating the password file does not re-set a live password.** Idempotency
   comes from a `pdbedit -L` guard: the oneshot only calls `smbpasswd -a` for
   users *not already* in the passdb. This is deliberate — it keeps activation
   from touching passwords on every rebuild — but it means changing the
   contents of a `passwordFile` has no effect on an already-provisioned user.
   To actually change a live password, remove the user from the passdb first
   and let the service re-add them:

   ```
   pdbedit -x -u alice     # drop alice from the SMB passdb
   systemctl restart setup-smb-passwords
   ```

## Usage

Import `default.nix` as a NixOS module and enable it:

```nix
{
  imports = [ ./samba-shared-folder ];

  # each SMB user must ALSO be a real system user
  users.users.alice = { isNormalUser = true; /* ... */ };

  modules.services.shared-folder = {
    enable = true;
    smbUsers.alice.passwordFile = "/run/secrets/alice-smb";
  };
}
```

Then open the firewall — either a scoped rule like
`networking.firewall.interfaces.eth0.allowedTCPPorts = [ 445 139 ]`
(preferred) or the module's all-interfaces `openFirewall = true` — and connect
from a client at `\\your-host\shared` (or `smb://your-host/shared`) as
`alice`.

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the share on. |
| `sharePath` | `/srv/shared` | Folder on disk, created `0770 root:<group>`. |
| `shareName` | `shared` | Share name clients see. |
| `group` | `shared` | Owning POSIX group; files are `force group`ed to it so members see each other's writes. |
| `workgroup` | `WORKGROUP` | SMB workgroup. |
| `interfaces` | `[]` | Subnets/interfaces to bind to. Empty = all; when set, `bind interfaces only` is enabled. |
| `openFirewall` | `false` | Opt-in: open SMB ports 445/139. Opens them on **all** interfaces regardless of `interfaces` — see Security notes. |
| `smbUsers` | `{}` | Attrset of `<user>.passwordFile`. At least one is required. |

The `passwordFile` should live outside the Nix store (an agenix/sops secret, or
a path under `/run`) — anything in the store is world-readable.

## Security notes

- **The firewall stays closed by default.** `openFirewall = false` means the
  share is unreachable from other machines until you open 445/139 yourself.
- **`openFirewall = true` opens 445/139 on every interface.** It maps to
  NixOS's `services.samba.openFirewall`, which is *not* scoped by the
  `interfaces` option — `interfaces` only controls the addresses smbd binds
  to, not the firewall. On a laptop that joins untrusted Wi-Fi, or any host
  with a public WAN interface, that exposes an authenticated SMB server to
  that network. SMB has a long history of pre-auth and auth-bypass CVEs, so on
  multi-homed or public-facing hosts keep `openFirewall = false` and add your
  own scoped rule, e.g.
  `networking.firewall.interfaces.eth0.allowedTCPPorts = [ 445 139 ]`.

## Design notes

- **`nmbd` is disabled.** No NetBIOS name broadcast, so clients connect by
  hostname or IP rather than by browsing the network neighborhood. One fewer
  service and one fewer open port.
- **`map to guest = Bad User` with `guest ok = no`.** Unknown usernames are
  mapped to guest and then rejected by the share (guests aren't valid users).
  The net effect is that a bogus username is denied *without* a password prompt
  — the mapping suppresses the prompt, the share still refuses access.
- The setup service orders `after`/`wants` `samba-smbd.service`, so the passdb
  is populated once smbd is up, and `RemainAfterExit` keeps it "active" so it
  doesn't re-run needlessly.
