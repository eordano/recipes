# remote-luks-unlock

Remotely unlock a LUKS-encrypted root over SSH from the **initrd**, so a
headless / remote machine with full-disk encryption can finish booting without
someone at the physical console.

## The problem

If your root filesystem is on LUKS, every boot halts at a passphrase prompt.
That is fine for a laptop, but a headless server in another room (or another
country) can never get past it — there is no keyboard, no console, nobody to
type the passphrase. The machine just sits in early boot forever.

This module brings up **networking and an SSH server inside the initrd**, before
the root filesystem is unlocked. You SSH in, type the passphrase, and the boot
continues. After that the initrd tears down and the normal system comes up.

## How to use it

```nix
{
  imports = [ ./remote-luks-unlock ];

  modules.unlock-ssh = {
    enable = true;

    # Dedicated PRIVATE initrd host keys (not your system host keys).
    hostKeys = {
      ssh_host_ed25519_key = "/run/secrets/initrd_host_ed25519_key";
    };

    # Who may connect to unlock. Defaults to root's authorizedKeys.
    authorizedKeys = [ "ssh-ed25519 AAAA... operator@example.com" ];

    # MUST match the real initrd interface name (check `ip link`).
    networkInterface = "enp1s0";

    # Optional: static addressing instead of DHCP.
    # static = {
    #   enable  = true;
    #   address = "192.168.1.50/24";
    #   gateway = "192.168.1.1";
    # };
  };
}
```

Then, from your workstation:

```sh
ssh -t root@your-host
# ... you are dropped straight into the passphrase prompt; type it; boot resumes
```

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `hostKeys` | — (required) | Attrset `filename -> private-key-path` for the initrd SSH host identity. |
| `authorizedKeys` | root's keys | Public keys allowed to connect and unlock. |
| `networkInterface` | `"eth0"` | Interface to bring up in the initrd. |
| `sshPort` | `22` | Port the initrd SSH server listens on. |
| `promptOnLogin` | `true` | Auto-run the password agent on login so connecting prompts immediately. |
| `static.enable` | `false` | Use a static IP instead of DHCP. |
| `static.address` | `""` | CIDR address, e.g. `192.168.1.50/24`. |
| `static.gateway` | `""` | Default gateway. |

## The traps (why this module is more than "start sshd in initrd")

Three non-obvious things will silently break a naive version of this. All are
handled here, but they are worth understanding because they also govern how you
*operate* it.

### 1. Answer with `--query`, not `--watch`

The initrd login shell runs:

```sh
systemd-tty-ask-password-agent --query
```

`--query` handles the one password request that is already pending, then
**exits** — so the SSH session closes cleanly on accept and the boot proceeds.
The tempting alternative, `--watch`, blocks forever waiting for future prompts
that never arrive, hanging your session. Use `--query`.

### 2. Connect with `ssh -t`

The password agent needs a **tty**. If you connect without a PTY, the agent has
no terminal to prompt on and the session just closes with no prompt at all.
Always `ssh -t`.

### 3. Configure the interface, or SSH binds to nothing

Without an explicit initrd network configuration, the interface comes up with
**no address**. The SSH server starts and "listens", but nothing can reach it.
This module always configures the interface — a static address when
`static.enable` is set, DHCP otherwise.

## The wrong-password lockout (a genuine dead end)

Know this before you rely on remote unlock:

- The disk stays locked and initrd SSH stays reachable, so on a *typo* you can
  simply SSH in again with the correct passphrase.
- **But `systemd-cryptsetup` gives up after 3 attempts.** Once you have entered
  three wrong answers, there is **no pending request** anymore — so
  `--query` finds nothing to answer, and there is no way to trigger a fresh
  prompt. The host is then locked out of remote unlock **until a reboot** puts
  it back at attempt one.

In short: remote unlock buys you convenience, not infinite retries. If you fat-
finger the passphrase three times you will need an out-of-band reboot (IPMI /
power cycle / a smart PDU) to try again. Plan a reboot path accordingly.

## Notes

- Use **dedicated** initrd host keys, separate from the running system's host
  keys. Their fingerprints differ from the booted system; pin them under a
  distinct `known_hosts` / `HostKeyAlias` entry so SSH does not warn on the
  identity change between the initrd and the full system.
- Store the private host key material with your secrets tooling of choice; this
  module only needs a path to the private key at build/activation time.
- Requires systemd-in-initrd (`boot.initrd.systemd.enable`), which this module
  turns on.
