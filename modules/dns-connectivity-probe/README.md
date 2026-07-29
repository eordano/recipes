# dns-connectivity-probe

A hardened, long-running systemd probe for diagnosing **intermittent** DNS and
reachability flaps — the kind that are gone by the time you SSH in to look.

## The problem

"DNS was broken for a bit around 3am" is unfalsifiable without evidence.
Interactive tools (`dig`, `ping` at the prompt) only tell you about *now*, and a
flap that lasts seconds every few hours never lines up with when you're watching.

This module runs a passive black-box probe: every few seconds it `dig`s and
`ping`s a fixed list of targets and appends one timestamped line per result. When
something breaks, you don't reproduce it — you `grep` the log:

```
grep -E 'FAILED|EMPTY' /var/log/dns-connectivity-probe/queries.log
```

and read off exactly when resolution or reachability broke, for how long, and
whether it was DNS (`DNS-FAILED`/`DNS-EMPTY`) or the path (`PING-FAILED`).
Including `localhost` plus an external name in the target list separates a
local-resolver failure from an upstream/WAN one.

## The traps this encodes

### 1. logrotate must use `copytruncate`

This is the load-bearing detail. The probe is a `while true` loop that holds the
log open with `>>` and **never reopens it** (it doesn't handle SIGHUP). A normal
rename-and-reopen rotation would move the file aside and expect the writer to
reopen the path — but this writer keeps writing to the same file descriptor,
which now points at the unlinked old inode. The "current" log silently stops
growing while your disk fills with an invisible deleted-but-open file.

`copytruncate` sidesteps this: logrotate copies the file's contents out to the
rotated name and then truncates the original **in place**, preserving the inode
the probe is still holding. You lose the theoretical few lines written between
copy and truncate — an acceptable trade for a probe whose whole point is to keep
writing to one stable fd.

### 2. Order after the local resolver

If you run a local resolver (dnsmasq, unbound, …), point `resolverService` at its
unit. The probe then `wants`/`after` it, so its first queries at boot don't record
spurious failures during the window before the resolver is up. Leave it `null` if
you have no local resolver.

### 3. Runs sandboxed as a DynamicUser

The unit needs no privileges — only outbound DNS/ICMP and one append-only log
dir. It runs under `DynamicUser` with `ProtectSystem=strict`, `ProtectHome`,
locked-down namespaces/kernel knobs, and `RestrictAddressFamilies` to
INET/INET6/UNIX. `LogsDirectory` gives it exactly one writable path.

## Usage

Import `default.nix` and enable it:

```nix
{
  imports = [ ./modules/dns-connectivity-probe ];

  modules.services.dns-connectivity-probe = {
    enable = true;
    targets = [ "localhost" "example.com" ];
    resolverService = "dnsmasq.service"; # or null
  };
}
```

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Turn the probe on. |
| `targets` | `[ "localhost" "example.com" ]` | Names to dig + ping each cycle. |
| `interval` | `5` | Seconds between cycles. |
| `digTimeout` | `2` | Per-query dig timeout (seconds). |
| `logDir` | `/var/log/dns-connectivity-probe` | Where `queries.log` lives; must be under `/var/log` (maps to `LogsDirectory`). |
| `keepRotations` | `6` | Rotated log files logrotate retains (hourly). |
| `resolverService` | `null` | Local resolver unit to order after, or `null`. |

## Caveats

- **It writes forever.** At the default 5s interval with a few targets this is a
  few log lines per second — small, but real. Rotation is hourly keeping 6 files;
  tune `keepRotations` for your retention.
- **`ping` needs ICMP to work.** Some networks/hosts drop ICMP even when
  everything is fine, which shows up as `PING-FAILED` noise. Trust the `DNS-*`
  lines for resolution; treat ping as a coarse reachability hint.
- **The probe never reopens its log** by design (that's why `copytruncate`
  exists). Don't "fix" it to handle SIGHUP and switch to a rename rotation unless
  you also make the script reopen the path.
