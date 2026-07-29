# wireguard-per-uid-exits

Bring up **N WireGuard exits side by side** and pin individual services to them
**by numeric uid**: one daemon leaves through exit A, another through exit B,
and everything else on the host leaves by the normal default route, untouched.

No network namespaces, no containers-with-their-own-stack, no `wg-quick`
all-or-nothing takeover. Each exit is a link, a routing table, a packet mark, an
`ip rule`, and one firewall rule per pinned uid. Optionally each exit also gets a
loopback SOCKS5 relay whose own uid is pinned, so unmodified clients can pick an
exit by connecting to a port.

The single thing to read before deploying this is **Trap 1**. Every other trap
here costs you an afternoon; Trap 1 costs you the whole idea, because without it
the tunnel does not come up at all and the failure looks exactly like "the VPN
provider is down".

## The problem

Policy routing by uid needs three pieces that live in three different
subsystems, and nixpkgs ships two of them with no way to connect them:

1. **A mark on the tunnel's own packets.**
   `networking.wireguard.interfaces.<name>.fwMark`
   (`nixos/modules/services/networking/wireguard.nix:172`) exists and its
   description even explains why you would want it — "the wireguard packets need
   to be routed differently". It is emitted as `wg set … fwmark` at
   `wireguard.nix:616`. Upstream stops there.

2. **A routing table with the tunnel as default route.**
   `networking.wireguard.interfaces.<name>.table` (`wireguard.nix:119`) puts the
   *AllowedIPs* routes into a table, and only when `allowedIPsAsRoutes` is on
   (`wireguard.nix:137`, used at `wireguard.nix:513`). You end up with a
   populated table and **nothing that ever selects it** — the module never
   creates an `ip rule`. `networking.wg-quick.interfaces.<name>.table`
   (`nixos/modules/services/networking/wg-quick.nix:143`, written into the conf
   at `wg-quick.nix:338`) delegates to `wg-quick`'s `Table = auto` magic, which
   is the opposite of what we want: it moves the *entire host* onto the tunnel.

3. **A rule that decides, per process, which packets get the mark.**
   This does not exist upstream in any form, because it cannot: the kernel's
   routing layer has no notion of a uid at packet-emission time. Only the
   firewall can see `skuid`. So the mark must come from nftables/iptables, and
   nixpkgs has no NixOS-level abstraction that writes such a rule.

systemd-networkd gets closest — the NixOS assertions accept both
`[WireGuard] FirewallMark=` (`nixos/modules/system/boot/networkd.nix:830`) and
`[RoutingPolicyRule] User=` (`networkd.nix:1368`), so pieces 1 and 2 and even a
uid-matching *route* rule can be declared there. Piece 3 still cannot: networkd
has no firewall, and the uid→mark decision has to happen in the output hook.

This module writes all three from one declaration, and — the part that is
actually hard — writes piece 3 in the one shape that does not eat itself.

## Trap 1 — the recursion guard, or nothing works

The generated marking rule is **two conditions, not one**:

```
meta skuid 900 meta mark != 400 meta mark set 200
└──── the uid ─┘└─ THE GUARD ──┘└─ select exit 0 ─┘
```

iptables backend, same shape:

```
iptables -t mangle -A OUTPUT -m owner --uid-owner 900 \
  -m mark ! --mark 400 -j MARK --set-mark 200
```

Delete `meta mark != 400` and the tunnel never completes a handshake. Here is
the exact sequence, for exit 0 with the default bases:

1. uid 900 writes to a TCP socket. The plaintext packet hits the output hook.
   `skuid` is 900, its mark is 0, `0 != 400` holds → **mark := 200**.
2. The chain is `type route`, so the kernel redoes the route lookup after the
   hook (see Trap 2). Rule priority 2000 matches `fwmark 200` → table 200 →
   `default dev wg-a`. Correct so far.
3. WireGuard encrypts it and emits a **new, outer UDP datagram** addressed to
   the peer endpoint on the internet. `wg set wg-a fwmark 400` stamps mark 400
   on that outer packet, and the outer packet **traverses the output hook
   again** — still presenting `skuid 900`, because it is generated in the
   context of the socket that caused it.
4. **With the guard**: `400 != 400` is false, the rule does not match, the mark
   stays 400, no `ip rule` matches 400, so the lookup falls through to `main`
   and the encrypted packet leaves by the physical interface. Which is the
   entire point — the outer packet must *not* go through the tunnel.
5. **Without the guard**: `skuid 900` matches, `meta mark set 200` **overwrites**
   the 400 that WireGuard just set (it is an assignment, not an OR), the route
   lookup selects table 200, and the encrypted packet is handed back to
   `wg-a` — which encrypts it again. Go to 3.

### What it looks like when you get it wrong

Nothing errors. Specifically:

- `wg show wg-a` shows the peer and a growing `transfer: … sent`, but
  **`0 B received`** and **no `latest handshake` line at all**.
- `tcpdump -ni <wan-iface> udp and host <endpoint>` shows **nothing** — not a
  rejected packet, not a retransmit. The handshake initiation never reaches the
  wire.
- `ip -s link show wg-a` TX counters climb steadily (the retries plus the
  recursion) while RX stays at zero.
- `dmesg` *may* show the kernel's generic loop protection firing —
  `Dead loop on virtual device wg-a, fix it urgently!` — but do not rely on it;
  the recursion is often absorbed silently.
- Every other service on the host is completely fine, which is why the first
  three hours go into "the provider must be having an outage".

### Why the guard belongs in the firewall rule here

`wg-quick`'s well-known kill switch solves the same recursion with
`ip rule add not fwmark $FWMARK table $FWMARK` — the guard lives in the *routing
rule*, phrased as "everything that did not come out of the tunnel goes into the
tunnel". That works because wg-quick is routing the whole host, so "everything"
is a legitimate selector.

Here the selector is a uid, and uids are only visible to the firewall. The
selection moved into the output hook, so **the guard had to move with it**. It is
the same idea one layer down, and the failure mode when it is missing is
identical.

### Two ways the guard itself can fail

- **It is an exact equality on the whole mark, not a masked bit test.** If
  anything else on the host writes marks on outgoing packets — mesh VPNs that
  OR a bit into the mark, container runtimes, QoS classifiers — the outer packet
  may arrive at the hook carrying `400 | <other bits>`. That is `!= 400`, the
  guard silently stops guarding, and you are back in the loop. Symptom is
  identical to having no guard, which makes it nasty to diagnose after the fact.
  The module has no mask option; if you share a host with another marker, use
  `markBackend = "manual"` and write the rule with a mask
  (`meta mark and 0x0000ffff != 400`) in a chunk you control.
- **The reverse direction:** `meta mark set 200` *clobbers* whatever mark another
  subsystem set on that uid's packets. If the pinned daemon also needs to be
  seen by a mark-based classifier, the classifier loses. Marks are a single
  32-bit field with no owner; treat this module as taking exclusive ownership of
  it for the pinned uids.

## Trap 2 — `type route`, not `type filter`

```nft
chain output {
  type route hook output priority mangle;
  …
}
```

`type route` is not decoration. Setting a mark in a `type filter` output chain
changes the packet's mark and **does not re-run the route lookup** — the routing
decision was already taken with mark 0, so the packet leaves by the default
route with the default source address and the `ip rule` you carefully created is
never consulted. `type route` is nftables' equivalent of iptables' `mangle
OUTPUT` and is what tells the kernel to reroute after the hook.

`priority mangle` is −150, i.e. before `filter` (0). The module puts this chain
in **its own `table inet <naming.nftTable>`**, separate from the NixOS firewall's
tables, so there is no interaction with `networking.firewall` rules beyond
ordering.

## Trap 3 — the mark alone does not fix the *source address*

This is the second-most expensive lesson in the module, and it is why
`pins.<name>.uidRangeRule.enable` exists.

Source-address selection happens during the route lookup that runs at
`connect()` time — **before** the output hook has stamped anything. So a socket
opened by a pinned uid gets the host's ordinary source address, and only later
does the packet get marked and rerouted into the tunnel. It leaves through the
tunnel carrying a source address the peer has never heard of. Nothing comes
back.

Symptom: TCP connections hang in SYN_SENT forever; `tcpdump -ni wg-a` shows your
SYNs going out with the host's LAN or public address as source instead of the
tunnel's `10.x` address.

The fix is a policy rule that makes the *route lookup itself* uid-aware, so the
tunnel route (and hence the tunnel source address) is chosen at `connect()`
time:

```
ip -4 rule add uidrange 900-900 lookup 200 priority 1500
```

`uidRangeRule.enable = true` installs exactly that, in a small oneshot unit
ordered after the exit's setup unit.

**When you do not need it:** any process that is *told* which interface to use —
`SO_BINDTODEVICE`, or an application-level `interface = …` / `bind-address`
setting. Binding to the device fixes source selection at `connect()` by other
means. This is precisely why the built-in SOCKS relay does not use a uidrange
rule: it is started as
`gost -L 'socks5://127.0.0.1:<port>?interface=wg-a'`, so gost binds itself.
If a relay's egress ever shows the host's address instead of the tunnel's, that
binding is what failed — and note the module offers no `extraRelayServiceConfig`
escape hatch, so granting it e.g. `CAP_NET_RAW` means overriding
`systemd.services.<relay unit>.serviceConfig` from your own configuration.

## Trap 4 — the numbering scheme, and how N tunnels avoid each other

Every number an exit needs is `<base> + index`. With the defaults, exit *i*
gets:

| Quantity | Option | Default base | Exit *i* | Where it appears |
| --- | --- | --- | --- | --- |
| Routing table id | `numbering.routeTableBase` | 200 | `200 + i` | `ip route add default dev <if> table N` |
| Selector mark | `numbering.fwmarkBase` | 200 | `200 + i` | `meta mark set N`, `ip rule … fwmark N` |
| **Tunnel mark** | `numbering.tunnelFwmarkBase` | 400 | `400 + i` | `wg set <if> fwmark N` — **the guard value** |
| `ip rule` priority | `numbering.rulePriorityBase` | 2000 | `2000 + i` | the fwmark rule |
| Relay uid | `numbering.relayUidBase` | 850 | `850 + i` | `users.users.<relay>.uid` |
| uidrange priority | `numbering.uidRangeRulePriorityBase` | 1500 | `1500 + j` | per *pin*, not per exit — see below |

**How N exits coexist.** A packet carries exactly one mark, and `meta mark set`
assigns rather than ORs, so a uid can only ever be on one exit — enforced at
evaluation:

```
services.wireguardExits: a uid is pinned to more than one exit; each uid can only have one egress.
```

Because uids are unique across exits, exit A's rule never sees exit B's outer
packets, and each rule's guard only has to know its *own* tunnel mark. That is
the whole coexistence argument: **disjoint uids ⇒ disjoint marks ⇒ disjoint
tables**. The tunnels themselves are independent links with independent peers
and never share a route.

Three things about the numbering that are *not* checked:

- **`routeTableBase + i` can reach reserved tables.** 253/254/255 are
  `default`/`main`/`local`. At base 200 that is exit index 53 — unreachable in
  practice, but also unasserted, and if you lower the base to squeeze into a
  free block you can hit it. Names in `/etc/iproute2/rt_tables` are also fair
  game for collisions.
- **The mark blocks are only 200 apart by default and nothing asserts they stay
  disjoint.** `fwmarkBase + i` must never equal `tunnelFwmarkBase + j` for any
  pair, or a guard starts comparing the wrong number and Trap 1 comes back.
- **`uidRangeRulePriorityBase` must be lower than `rulePriorityBase`**; the
  option documents this as a requirement and no assertion enforces it.

**The index is alphabetical, not declaration order.** `index = null` (the
default) assigns the exit's position in `lib.attrNames cfg.exits`, which Nix
returns **sorted**. Adding an exit whose name sorts early renumbers every exit
after it: marks move, table ids move, and — worst — **relay uids move**, so
files owned by the old relay uid now belong to a different exit's relay. Set
`index` explicitly on any deployment where a number has leaked into something
durable.

**The uidrange priority index `j` is worse.** It is an allocation counter over
*all* uidrange-enabled pins across all exits, in alphabetical exit order then
pin order. Add a pin anywhere and later pins shift priority. Each pin unit only
deletes rules at *its own* priority before adding its own, so a renumber can
leave a stale rule behind at the vacated priority. Set
`pins.<name>.uidRangeRule.priority` by hand if you care. Note this number is
**not** exposed in `slots`.

**Read numbers from `slots`, never recompute them.** The module exports a
read-only `services.wireguardExits.slots.<exit>` with `index`, `interface`,
`routeTable`, `fwmark`, `tunnelFwmark`, `rulePriority`, `relayUid`,
`runtimeDir`, `setupUnit`. Both `slots` and `nftRuleset` are defined *outside*
the `mkIf`, so a consumer module can read them without depending on `enable` —
that is deliberate, and it is why a readOnly option here carries no `default`
(`lib/modules.nix` treats a default as one of the definitions it refuses to
stack).

## Trap 5 — there is no kill switch; an empty table falls through

Policy routing rules are not terminal. If the rule matches but the table it
names contains **no matching route**, the lookup continues down the rule list to
`main` at priority 32766.

Exit *i*'s table contains exactly one route, `default dev wg-x`. The kernel
deletes that route the moment the link goes away — and the setup script itself
starts with `ip link del "$IFACE"` on every (re)start. So:

**Whenever the tunnel is down, the pinned daemon silently leaves by the host's
normal default route, with the host's normal source address.** No error, no log
line, no connection failure. It just stops being pinned.

The module ships no fail-closed behaviour. Choose one and add it yourself,
*before* putting anything sensitive behind an exit:

```nix
# A blackhole at a worse metric: the tunnel route (metric 0) wins while it
# exists, the blackhole takes over the instant it does not.
systemd.services."wireguard-exit-fallback-ams" = {
  wantedBy = [ "multi-user.target" ];
  after = [ "wireguard-exit-ams.service" ];
  requires = [ "wireguard-exit-ams.service" ];
  path = [ pkgs.iproute2 ];
  serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
  script = ''
    ip route replace blackhole default \
      table ${toString config.services.wireguardExits.slots.ams.routeTable} \
      metric 1000
  '';
};
```

It must be a separate unit ordered *after* the setup unit, because the setup
script runs `ip route flush table "$TABLE"` and would wipe a route added before
it. The nftables alternative is a second chain that rejects marked packets on
the wrong interface:

```nft
chain egress-guard {
  type filter hook output priority 0;
  meta mark 200 oifname != "wg-ams" reject
}
```

## Trap 6 — IPv6 is marked but not routed

**This is the one place the module is internally inconsistent rather than merely
limited, and on a dual-stack host it is a leak.**

- The marking half is family-agnostic. `table inet` matches IPv4 *and* IPv6, and
  the iptables backend uses `ip46tables`, which applies the rule to both
  `iptables` and `ip6tables`.
- The routing half is IPv4-only. The setup script extracts only the v4 address
  from the conf's `Address` line (`grep -v ':' | head -1`), adds only that to the
  link, and runs `ip route add default …` and `ip rule add fwmark …` with **no
  family flag** — and `ip`'s default family is `AF_INET`. The uidrange pin unit
  is explicitly `ip -4`.

Consequence: a pinned uid's IPv6 packets get marked, find no IPv6 rule for that
mark, fall through to the v6 `main` table, and leave via the host's normal IPv6
route with the host's real global address. On a host with working IPv6 talking
to anything with an AAAA record, that is most of the traffic — and it is exactly
the traffic the exit existed to hide.

Pick one before you deploy:

1. **Turn IPv6 off** for the host or for the pinned daemon (application-level
   `-4`, or no v6 default route).
2. **Reject marked v6** in nftables, so the failure is loud:
   `meta nfproto ipv6 meta mark 200 reject`.
3. **Add the v6 half yourself** in a unit ordered after the setup unit: extract
   the v6 `Address`, then `ip -6 addr add`, `ip -6 route add default dev`,
   `ip -6 rule add fwmark <mark> lookup <table>`. Routing tables are per-family,
   so table id 200 in `inet6` is a *different* table from table 200 in `inet`
   and reusing the id is safe.

Verify with `curl -6` run as the pinned uid, not with the browser.

## Trap 7 — DNS does not follow the uid

The module parses exactly four fields out of the WireGuard conf — `PrivateKey`,
`Address`, `PublicKey`, `Endpoint`. **The provider's `DNS =` line is ignored**,
along with `MTU`, `Table`, `PreUp`/`PostUp`. Nothing about resolution changes
when you pin a uid, and two stock NixOS defaults make that worse than it sounds:

- **`services.nscd.enable` defaults to `true`** and **`enableNsncd` defaults to
  `true`** (`nixos/modules/services/system/nscd.nix:24` and `:34`), and the
  daemon runs as its own user (`nscd.nix:44`). glibc routes `hosts` lookups
  through that socket, so **the actual DNS query is emitted by the nsncd
  process, owned by the `nscd` uid — not by your pinned uid.** It leaves by the
  default route.
- A caching stub resolver on loopback (`systemd-resolved` on 127.0.0.53,
  `dnsmasq`, `dnscrypt-proxy`, `unbound`) has the same shape: your process talks
  to loopback, the stub makes the upstream query as *its* uid.

So your payload traffic goes through the exit while the upstream DNS server
learns every name you asked for, from your real address, in the right order and
at the right time. That is enough to undo the exercise.

Not every program is affected — Go and Rust programs commonly resolve
in-process, bypassing NSS entirely, in which case the query *is* owned by the
pinned uid and *does* enter the tunnel. Check per program with
`tcpdump -ni wg-x port 53`; do not assume.

Fixes, in rough order of effort:

- **Use the SOCKS relay with remote DNS.** A SOCKS5 client that sends a
  *hostname* (curl's `socks5h://`, not `socks5://`) makes the relay resolve, and
  the relay's uid is pinned. This is the cheapest correct answer.
- **Pin the resolver too.** Give the pinned daemon its own resolver instance and
  add that resolver's uid as a second pin on the same exit.
- **Configure the application's resolver** directly at the tunnel's DNS address.

## Trap 8 — `DynamicUser` can never be pinned

The uid → mark rule is compiled into the firewall ruleset at **build time**.
`DynamicUser = true` allocates a uid from the transient range (61184–65519) at
**unit start**, and it can differ between starts. There is no expressible rule.

Use a static uid: `users.users.<name> = { isSystemUser = true; uid = <n>; }`.
Pick from a block nothing else claims — NixOS's own static assignments are in
`nixos/modules/misc/ids.nix`, and the relay uids default to the 850+ block.

The corollary for the mark rule is that `meta skuid` matches the **socket
owner**, so anything the kernel emits without a socket — ICMP errors, some TCP
resets — does not match and leaves by the default route.

## Trap 9 — containers must share the host's network namespace

A pinned service inside a container with its **own** network namespace is
invisible to this mechanism. Its packets traverse *that* namespace's output
hook, get bridged or NATed on the way out, and by the time they reach the host's
output chain they have no owning socket at all. `meta skuid` never matches, and
the traffic leaves by the default route.

The working shape is host networking plus a matching uid:

```nix
virtualisation.oci-containers.containers.<name> = {
  user = "900:900";
  extraOptions = [ "--network=host" ];
};
```

with `users.users.<name>.uid = 900` on the host and `pins.<name>.uid = 900`.
The uid inside the container must be the same *number* as the host uid — the
kernel compares numbers, and the container's `/etc/passwd` is irrelevant. The
same applies to `meta skuid` generally: it wants an integer, which is why
`pins.<name>.uid` is `types.int` and not a username.

## Trap 10 — the two firewall backends are mutually exclusive, and `manual` exists for a real reason

`markBackend` defaults to `nftables` when `networking.nftables.enable` is set and
`iptables` otherwise.

- **`iptables`** writes into `networking.firewall.extraCommands` /
  `extraStopCommands`, which the nftables firewall **hard-asserts must be
  empty** (`nixos/modules/services/networking/firewall-nftables.nix:65` and
  `:69`). The module mirrors that as its own assertion so you get a legible
  message instead of upstream's.
- **`nftables`** appends its table with `lib.mkAfter` to
  `networking.nftables.ruleset`.
- **`manual`** emits no firewall configuration at all and hands you
  `config.services.wireguardExits.nftRuleset` to place yourself:

  ```nix
  networking.nftables.ruleset = lib.mkAfter config.services.wireguardExits.nftRuleset;
  ```

  Use it when something else on the host also appends to the ruleset.
  `mkAfter` chunks concatenate in module **collection** order, so a table
  emitted from an *imported* module lands after every table emitted by the
  importing module's siblings. The resulting ruleset behaves identically, but it
  is a different file — a different `/etc` derivation, and therefore a different
  system closure. If you are chasing byte-identical closures, or you own the
  whole ruleset, take `manual`.

## Trap 11 — key handling: `types.str`, not `types.path`

`configFile` and `configBundle.zipPath` are deliberately `types.str`. A
`types.path` would be **copied into the world-readable Nix store**, publishing
the tunnel's private key to every user on the machine and to every host that
pulls the closure. This is the single most common way a WireGuard private key
gets leaked on NixOS, and the option types are the only thing standing between
you and it.

Point them at a decrypted-secret path or a `LoadCredential` destination:

```nix
extraSetupServiceConfig.LoadCredential = "conf:/run/secrets/exit-ams-conf";
configFile = "/run/credentials/wireguard-exit-ams.service/conf";
```

Note that the credential path embeds the **unit name**, which is
`<naming.setupUnitPrefix>-<exit>.service` — change `setupUnitPrefix` and every
credential path changes with it.

At runtime the key lands in `/run/<naming.runtimeDirectory>/<exit>/private-key`,
directory `0700`, file `0400`, root-owned, and is handed to `wg set` as a
**file**, so it never appears in a command line or in `/proc/<pid>/cmdline`.

Two parsing details that will bite:

- The extractor is `grep -oP '<Field>\s*=\s*\K.*'`, so it needs PCRE. nixpkgs'
  `gnugrep` 3.12 is built against pcre2
  (`pkgs/by-name/gn/gnugrep/package.nix:60`), so `-P` is available — but a
  slimmer grep in `path` would break it.
- **CRLF is not stripped.** `.*` takes the rest of the line verbatim. A provider
  bundle with DOS line endings gives you a private key with a trailing `\r` and
  the unit dies with:

  ```
  Key is not the correct length or format
  ```

  `PublicKey` and `Endpoint` get `tr -d ' '` but not `tr -d '\r'`. Preprocess
  the bundle if your provider ships CRLF.

## Trap 12 — restarting the setup unit re-rolls the server and does not restart the relay

With `configBundle`, one `.conf` is chosen with `shuf -n1` **on every start** of
the setup unit. That is a feature — `systemctl restart <setup unit>` rotates to
another server with no configuration change — and a hazard: any activation that
restarts the unit moves your egress to a different city and changes your public
address mid-session.

The relay unit declares `after` + `requires` on the setup unit. `Requires=`
propagates *stop* and *start failure*, **not restart**. So a setup restart
deletes and recreates the link underneath a still-running relay. If you want
that deterministic, add it yourself:

```nix
systemd.services."<relay unit>".bindsTo = [ "<setup unit>.service" ];
systemd.services."<relay unit>".partOf  = [ "<setup unit>.service" ];
```

Related: the setup unit is `Type = oneshot` with `RemainAfterExit` and **no
`ExecStop`**. `systemctl stop` removes `/run/<dir>/<exit>` (taking the private
key with it, which is good) and leaves the **interface, the routing table and
the `ip rule` in place**. Removing an exit from your configuration removes the
unit, not the live state — the link and its rules survive until reboot or a
manual `ip link del` / `ip rule del`. A stale rule pointing at a now-empty table
is precisely Trap 5.

## Trap 13 — `trustInterface` is off for a reason

`networking.firewall.trustedInterfaces` accepts **everything** arriving on the
interface without consulting the input chain. A commercial exit is an untrusted
network and its peer can address you on your tunnel address, so turning this on
exposes every socket bound to `0.0.0.0` to the provider and to whatever else is
on that tunnel.

Turn it on only when something must accept inbound *through* the tunnel — a
torrent client with a forwarded port is the standard case — and audit
`ss -lntup` first. Note the effect is host-wide even though the option is
per-exit.

## Usage

```nix
{ config, lib, ... }:
{
  imports = [ ./wireguard-per-uid-exits ];

  users.groups.scraper.gid = 900;
  users.users.scraper = {
    isSystemUser = true;
    group = "scraper";
    uid = 900;              # static — see Trap 8
  };

  services.wireguardExits = {
    enable = true;
    providerLabel = "AcmeVPN";
    markBackend = "nftables";

    exits = {
      # Exit 0 (alphabetically): a single fixed config, one pinned daemon.
      alpha = {
        index = 0;          # pin it — see Trap 4
        configFile = "/run/credentials/wireguard-exit-alpha.service/conf";
        extraSetupServiceConfig.LoadCredential = "conf:/run/secrets/exit-alpha";
        pins.scraper = {
          uid = 900;
          uidRangeRule.enable = true;   # not bound to a device — see Trap 3
        };
      };

      # Exit 1: a provider bundle plus a SOCKS relay for unmodified clients.
      beta = {
        index = 1;
        configBundle = {
          zipPath = "/run/secrets/exit-beta.zip";
          select = [ "xx-yyy-wg-*" ];
        };
        socksRelay = {
          enable = true;
          port = 10811;
        };
      };
    };
  };
}
```

That yields, with the default bases:

| | `alpha` (i=0) | `beta` (i=1) |
| --- | --- | --- |
| interface | `wg-alpha` | `wg-beta` |
| table | 200 | 201 |
| selector mark | 200 | 201 |
| tunnel mark | 400 | 401 |
| rule priority | 2000 | 2001 |
| relay uid | — | 851 |
| pinned uids | 900 | 851 (the relay) |

Consumers read the numbers back out of `slots`:

```nix
after    = [ "${config.services.wireguardExits.slots.alpha.setupUnit}.service" ];
lookupTable = config.services.wireguardExits.slots.alpha.routeTable;
```

### Verifying it

Run all of these; the first two catch Trap 1, the third catches Trap 3, the
fourth catches Trap 6.

```bash
# 1. Handshake completed and bytes came back. "0 B received" ⇒ Trap 1.
wg show wg-alpha

# 2. The guard is present in the live ruleset.
nft list table inet wireguard-exits-mark | grep 'meta mark !='

# 3. The pinned uid sees a different address than the host does.
sudo -u '#900' curl -4 -s https://<ip-echo-endpoint>/
curl -4 -s https://<ip-echo-endpoint>/

# 4. The same, over IPv6. If these two agree, you are leaking (Trap 6).
sudo -u '#900' curl -6 -s https://<ip-echo-endpoint>/

# 5. Rules and routes. NOTE: ip prints marks in HEX — 200 shows as 0xc8.
ip rule show
ip route show table 200

# 6. Where the DNS query actually goes (Trap 7).
tcpdump -ni wg-alpha port 53

# 7. Through the relay, with remote DNS.
curl -s --proxy socks5h://127.0.0.1:10811 https://<ip-echo-endpoint>/
```

### The automated test

`test.nix` next to this README is a six-node NixOS VM test built on
`lib/nixos-test-topology`. Run it standalone:

```bash
nix-build test.nix --arg pkgs 'import <nixpkgs> { system = "x86_64-linux"; }'
```

It stands up two independent exits and one echo server, and asserts that three
uids on one host reach that single destination from three *different* observed
source addresses — exit A's, exit B's, and the host's own — with netfilter
counters on both the client and each exit proving the packets took the claimed
path rather than merely arriving.

The recursion guard of Trap 1 is covered by a **negative control node**, not by
a `grep` of the ruleset: a second machine runs this module with
`markBackend = "manual"` and installs the module's own generated ruleset with
just the `meta mark != <tunnelFwmark>` clause deleted. Its traffic dies while
its handshake stays alive, and a counter shows the encrypted outer datagrams
being marked back into the tunnel that produced them.

Two things that test pinned down and that are worth knowing when you debug this
by hand:

- **Handshake and keepalive packets are not affected by a missing guard.** They
  are generated by the kernel with no socket attached, so `meta skuid` never
  matches them. A tunnel with no guard at all still shows `latest handshake`.
  Trap 1's `wg show` symptom ("0 B received", no handshake line) is what you see
  when the guard is missing *and* something keeps re-triggering handshakes; the
  reliable tell is that data does not flow while the handshake does.
- **`interface = "eth<vlan>"` in a topology is a trap of its own.** A node whose
  legs are vlan 2 and vlan 3 gets kernel names `eth1`/`eth2` and target names
  `eth2`/`eth3`; renaming `eth1` to the still-occupied `eth2` fails
  (`Failed to rename network interface 3 from 'eth1' to 'eth2': File exists`)
  and the node boots with an unconfigured leg. The test names its subnets
  `lan0`/`wan0`/`svc0` for that reason.

## Options

| Option | Default | Effect |
| --- | --- | --- |
| `services.wireguardExits.enable` | `false` | Nothing is configured until this is on. `slots` and `nftRuleset` are still readable. |
| `.providerLabel` | `"VPN"` | Label in unit descriptions and log lines. Changing it produces a closure diff. |
| `.markBackend` | `nftables` if `networking.nftables.enable`, else `iptables` | `nftables` / `iptables` / `manual` (Trap 10). |
| `.naming.interfacePrefix` | `"wg-"` | Prefix + exit name must be ≤ 15 chars (`IFNAMSIZ`), asserted. |
| `.naming.setupUnitPrefix` | `"wireguard-exit"` | Setup unit is `<prefix>-<exit>.service`; also decides `LoadCredential` paths. |
| `.naming.relayUnitPrefix` / `.relayUserPrefix` / `.relayGroup` | `wireguard-exit-relay` | Relay unit, user and shared group names. |
| `.naming.runtimeDirectory` | `"wireguard-exits"` | Per-exit state at `/run/<this>/<exit>`, mode `0700`. |
| `.naming.nftTable` | `"wireguard-exits-mark"` | Name of the `table inet` holding the marking chain. |
| `.numbering.*` | see Trap 4 | Bases for table id, selector mark, tunnel mark, rule priority, relay uid, uidrange priority. |
| `.exits.<name>.index` | `null` | Explicit slot. `null` ⇒ **alphabetical** position (Trap 4). |
| `.exits.<name>.configFile` | `null` | Runtime path of a `.conf`. `types.str` on purpose (Trap 11). |
| `.exits.<name>.configBundle` | `null` | `{ zipPath; select; }` — one entry picked at random per start (Trap 12). Exactly one of `configFile`/`configBundle`, asserted. |
| `.exits.<name>.allowedIPs` | `"0.0.0.0/0"` | Peer `AllowedIPs`. Cryptographic routing, not a route — no default route is ever added to `main`. |
| `.exits.<name>.mtu` | `1280` | 1280 survives every path; 1420 is the usual max over a 1500-byte v4 path. Raising it invites the "TLS completes, large responses hang" PMTU black hole. |
| `.exits.<name>.persistentKeepalive` | `25` | Keeps the provider's NAT mapping alive. |
| `.exits.<name>.trustInterface` | `false` | Adds the link to `trustedInterfaces` (Trap 13). |
| `.exits.<name>.socksRelay.enable` | `false` | Loopback SOCKS5 relay whose own uid is pinned to this exit. |
| `.exits.<name>.socksRelay.port` | `null` | Required when enabled; uniqueness across exits is asserted. |
| `.exits.<name>.socksRelay.package` | `pkgs.gost` | Needs gost **v3** — nixpkgs 26.11 ships 3.2.6 (`pkgs/by-name/go/gost/package.nix:12`). The `?interface=` dialer parameter is v3 syntax. |
| `.exits.<name>.pins.<pin>.uid` | — | Static numeric uid pinned to this exit (Trap 8). |
| `.exits.<name>.pins.<pin>.uidRangeRule.enable` | `false` | Also install an `ip rule … uidrange` so source selection is uid-aware (Trap 3). |
| `.exits.<name>.pins.<pin>.uidRangeRule.priority` | `null` | `null` ⇒ `uidRangeRulePriorityBase + <allocation index>`, which shifts when pins are added. |
| `.exits.<name>.extraSetupServiceConfig` | `{ }` | Merged into the setup unit's `serviceConfig` with `//` — it can override `Type`, `RuntimeDirectory`, etc. Intended for `LoadCredential`. |
| `.nftRuleset` | read-only | The computed marking table, for `markBackend = "manual"`. |
| `.slots` | read-only | Per-exit computed numbers. Read these; never recompute `base + index`. |

Assertions cover: `IFNAMSIZ`; exactly one config source; relay port present and
unique; one uid pinned to at most one exit; unique indices; and backend
compatibility with `networking.nftables.enable`.

## Caveats and known gaps

- **IPv6 is marked but not routed.** The most important gap; see Trap 6. Treat
  the module as IPv4-only until you add the v6 half.
- **No fail-closed mode.** See Trap 5. This module *pins* egress; it is not a
  kill switch, and the difference only shows up when the tunnel is down.
- **DNS is out of scope.** See Trap 7.
- **No teardown.** No `ExecStop`; links, tables and rules outlive the units and
  the configuration that created them.
- **The mark is unmasked and exact.** Coexisting mark users break the recursion
  guard in both directions (Trap 1).
- **`declarationOrder` in the source is a misnomer** — it is built from
  `lib.attrNames`, which is sorted. The behaviour matches the option
  documentation ("alphabetically sorted"), the internal name does not.
- **Numbering-block overlap and reserved table ids are unasserted**, as is
  `uidRangeRulePriorityBase < rulePriorityBase` (Trap 4).
- **The uidrange rule priority is not exported in `slots`**, so an external
  module cannot avoid colliding with it without recomputing the allocation.
- **Relay units have no `extra…ServiceConfig` option**, unlike setup units;
  override `systemd.services.<relay unit>` directly if you need capabilities or
  hardening on them.
- **`select` glob patterns are interpolated into a shell `case` unquoted.** They
  are configuration, not input, but a pattern containing shell metacharacters
  will produce a script that does something other than what you meant. The
  "nothing matched" error path prints the full list of available server names
  into the journal.
- **Version bounds.** Written against nixpkgs 26.11 — `gost` 3.2.6, `gnugrep`
  3.12 with pcre2, iproute2 with `uidrange` support (≥ 4.10), and a kernel with
  `meta skuid` in `type route` output chains (nftables ≥ 0.9, kernel ≥ 4.10).
  `wg set … fwmark` has been stable since WireGuard's kernel merge in 5.6.
- **This pins egress; it does not confine a process.** A pinned daemon that can
  reach another local service, hand a socket to another uid, or exec something
  running as a different user is not contained. For "this uid may only reach
  these domains, enforced in the kernel", see
  [`per-uid-egress-lockdown`](per-uid-egress-lockdown.md); for per-*process*
  egress rules, [`opensnitch-store-path-rules`](opensnitch-store-path-rules.md);
  for interface-level allowlists, [`egress-filter`](egress-filter.md). The
  closest relative is [`tailscale-exit-bypass`](tailscale-exit-bypass.md), which
  solves the mirror-image problem — diverting chosen destinations *off* an exit
  — with the same fwmark and policy-routing machinery.
