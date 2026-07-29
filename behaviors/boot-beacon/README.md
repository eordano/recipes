# boot-beacon

Emit `BEACON`-prefixed marker lines to the journal (and thus the serial/EFI
console) as a host finishes booting, answering the two questions that matter
during an unattended reboot or a remote reinstall:

- **What address do I SSH to?**
- **Did this box rejoin the tailnet?**

A deploy script can `grep` them out of a noisy console log; a human can watch
them scroll past on IPMI/serial during a blind reboot.

## The problem

When you reboot or reinstall a headless machine you can't reach, you have no
way to know it came back up, and no way to know *where* to reach it — DHCP may
have handed it a new address, a new NIC may have become primary, or the tailnet
join may have silently failed. The only channel you have is the serial console
or an out-of-band framebuffer.

This module is deliberately **local-only**: no daemon, no outbound call,
nothing to configure on the receiving side. It just prints. That is the whole
point — it works when the console is the *only* channel left, which is exactly
the recovery path for headless VPN gateways and exit nodes.

## Key insight / traps

- **Read the IP from the default route's `prefsrc`, not from "any global
  address".** `prefsrc` is the source address the kernel actually uses for
  outbound traffic — i.e. the correct "reach me here" address on a multi-homed
  box. Grabbing the first global-scope IPv4 can hand you a management/second-NIC
  address nobody can SSH to. The module uses `prefsrc` first and only falls back
  to the first global IPv4, then to `ip=unknown`, so it never fails.

- **The units must never wedge `multi-user.target`.** Both are
  `Type = oneshot` with `RemainAfterExit = true`, and the tailnet beacon exits
  **successfully even on timeout**. An informational beacon that could block the
  boot would defeat its own purpose. The timeout (`tailscaleTimeoutSec`, default
  300s) bounds only the tailnet wait; the plain readiness line fires as soon as
  `network-online.target` is reached.

- **`RemainAfterExit` means you read the marker after the fact.** The units show
  `active (exited)` and won't re-emit until the next boot. Read them with
  `journalctl -u boot-beacon` / `-u tailscale-beacon`, or watch the console live
  during the reboot.

- **The tailnet beacon honours a pinned tailscale.** It resolves the binary
  through `config.services.tailscale.package`, so an overridden/pinned Tailscale
  is used rather than whatever is on `PATH`.

## Usage

Import the module and enable it:

```nix
{
  imports = [ ./behaviors/boot-beacon ];

  behaviors.bootBeacon.enable = true;
  # optional; default 300
  # behaviors.bootBeacon.tailscaleTimeoutSec = 120;
}
```

The `tailscale-beacon` unit only materializes when
`services.tailscale.enable = true`; on a host without Tailscale you just get the
`ready-for-ssh` beacon.

### Output

```
BEACON ready-for-ssh host=your-host ip=192.0.2.17
BEACON tailscale-up host=your-host ts_ip=100.x.y.z
```

or, if the tailnet join didn't complete in time:

```
BEACON tailscale-timeout host=your-host state=NoState
```

## Options

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `behaviors.bootBeacon.enable` | bool | `false` | Enable the beacons. |
| `behaviors.bootBeacon.tailscaleTimeoutSec` | int | `300` | Seconds to wait for tailscale to reach `Running` before emitting the timeout beacon (still exits 0). |

## Caveats

- Beacons are plaintext on the console/journal by design. They reveal a
  hostname and an IP — fine for a recovery aid, but don't treat the console as
  private.
- IPv4-only as written. If you're IPv6-only, adapt the `ip -4` / `tailscale ip
  -4` calls.
