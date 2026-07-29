# headscale IP reservations

A timer that compares the addresses headscale actually handed out against the
addresses you expect each host to hold, and fails the unit when they diverge.

## Why

headscale assigns tailnet addresses from its own pool. Nothing in headscale
pins a host to an address, so anything that re-registers a node — a reinstall,
a wiped state directory, an expired key, a machine rejoining after its record
was deleted — can hand it a different one.

That matters as soon as any address is load-bearing: an ACL that names a host
by address, a firewall rule, a monitoring target, a DNS record, a peer config
written by hand. When the address moves, none of those fail loudly. The ACL
still parses. The rule still loads. They simply stop matching the machine they
were written for, and you find out when something that should have been
reachable is not, or — worse — something that should have been blocked is not.

The check turns that silent drift into a failed systemd unit.

## What it detects

Three distinct faults, reported separately because they mean different things:

- **duplicates** — two or more nodes claim one hostname. This is the
  re-registration case: headscale keeps the old row and appends a suffix to
  the new node's `given_name` (`myhost` → `myhost-1`), so the fleet now has
  two rows for one machine and only one of them is live.
- **wrong_ip** — the node exists but does not hold the address you reserved
  for it. Something else took the address, or this node was reassigned.
- **missing** — a host you reserved an address for is absent from headscale
  entirely.

Reconciliation is on the *reported hostname*, not on `given_name`, precisely
because `given_name` is what headscale mangles when a name collides.

Nodes you have not reserved an address for are ignored. Phones and tablets
routinely register with no useful hostname — several arrive as `localhost` —
and treating those as duplicates would make the check cry wolf permanently.

## Usage

```nix
modules.services.headscale-ip-reservations = {
  enable = true;
  reservations = tailnetAddresses;   # host name -> reserved address
  interval = "hourly";
};
```

Point `reservations` at whatever already declares your addresses — the same
attrset your ACL policy or DNS records are generated from. The value of this
check comes from it comparing headscale against your *single source of truth*;
maintaining a second hand-written list here would just create a third thing to
drift.

| option | default | meaning |
|---|---|---|
| `reservations` | `{ }` | host name → reserved tailnet address |
| `headscaleCommand` | the configured `services.headscale` package | override when headscale runs elsewhere, e.g. in a container |
| `reportMissing` | `true` | whether an absent reserved host is a failure |
| `interval` | `hourly` | systemd `OnCalendar` expression |

`reportMissing = false` is for fleets where some reserved machines are
legitimately offline for long stretches — a laptop that travels, a host that is
powered down between jobs. Leave it on if every reserved host is expected to be
registered at all times, because "missing" is otherwise indistinguishable from
"quietly deleted".

## Traps

**This is a detector, not a fix.** It tells you an address moved; it does not
move it back. Reassigning is a headscale-side operation and doing it
automatically would be the wrong default — the right response to a duplicate is
usually to delete the stale row, and no check should delete node records on its
own.

**It needs to reach headscale's CLI.** The default resolves the binary from
`services.headscale` on the same host. If headscale runs in a container or on
another machine, set `headscaleCommand` to something that reaches it; the unit
runs as root and shells out, so a wrapper script is fine.

**A node with no addresses at all is reported as `wrong_ip`, not `missing`.**
It is registered, so it is present; it simply holds nothing matching the
reservation. That is the honest classification, but it reads oddly the first
time.
