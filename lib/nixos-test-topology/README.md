# nixos-test-topology

A topology builder and fixture library for `pkgs.testers.runNixOSTest`. Declare
subnets and hosts once; get back per-node NixOS modules that assign **exactly**
the addresses you asked for, plus those addresses as plain strings for the
testScript. Ships with a secrets stub, a source-address echo server, and a
netfilter FORWARD-hook packet counter — the instrument that separates "the
request failed" from "the request reached the router and was filtered".

Everything below was re-verified against nixpkgs 26.11 (`nixos-unstable`,
2026-07). Line numbers are repo-relative paths into that tree.

## The problem

The NixOS test framework assigns IP addresses for you, and the scheme it uses is
not written down anywhere a test author will find it. Hand-picking an address in
a multi-node test is therefore a gamble against your own node *naming*, and when
you lose, the symptom appears somewhere else entirely — a `wait_until_succeeds`
that hangs in an unrelated later step, because two machines are ARPing for one
address.

`mkTopology` takes the address assignment away from the framework instead of
fighting it:

```nix
topo = (import ./lib/nixos-test-topology).mkTopology {
  subnets = { guest.vlan = 1; uplink.vlan = 2; };
  hosts = {
    browser = { addresses.guest = 50; via = "gateway"; };
    gateway = { addresses = { guest = 1; uplink = 1; }; forward = true; };
    origin  = { addresses.uplink = 80; via = "gateway"; };
  };
};

nodes.browser = { ... }: { imports = [ topo.nodes.browser ]; };
# browser: 10.1.0.50/24 on eth1, and nothing else.
# topo.ip.origin.uplink == "10.2.0.80"
# topo.iface.uplink     == "eth2"
```

## Trap 1 — the auto-assigned address depends on ALPHABETICAL node rank

`virtualisation.vlans = [ N ]` is not a low-level knob. It desugars into a named
interface carrying `assignIP = true`
(`nixos/modules/virtualisation/guest-networking-options.nix:41-53`, the flag is
set on line 50). The test framework then gives that interface
`192.168.<vlan>.<nodeNumber>` (`nixos/lib/testing/network.nix:41`), and
`nodeNumber` comes from

```nix
nodeNumbers = listToAttrs (
  zipListsWith nameValuePair (attrNames testModuleArgs.config.allMachines) (range 1 254)
);
```

— `nixos/lib/testing/network.nix:25-27`. `builtins.attrNames` returns keys
**sorted**, so a node's address is decided by where its name falls
alphabetically among *all* nodes in the test. Add a node called `aardvark` later
and every existing node shifts by one.

Probe with three nodes declared in the order `zulu, alpha, mike`, all on vlan 1:

```
alpha → 192.168.1.1     mike → 192.168.1.2     zulu → 192.168.1.3
```

Source order is irrelevant; `alpha < mike < zulu` is what decided it.

## Trap 2 — `networking.interfaces.*.ipv4.addresses` is a LIST, so it MERGES

Set an address by hand next to `virtualisation.vlans` and you do not replace the
framework's; you *append* to it. The framework writes its definition through
`networking.interfaces = listToAttrs ipInterfaces`
(`nixos/lib/testing/network.nix:57`), and list options concatenate.

Same probe, with `mike` additionally hand-picking `192.168.1.1`:

```
mike's eth1 addresses = [ "192.168.1.1", "192.168.1.2" ]
```

`mike` now holds `192.168.1.1` — which is also `alpha`'s address. Two machines
answer ARP for one address on one VLAN. Nothing fails at that moment; it fails
later, wherever traffic to `alpha` happens to land on `mike`.

## Trap 3 — `mkForce` on the address list is the WRONG fix

The obvious repair is `lib.mkForce [ { address = ...; } ]`. It does clean up the
interface, and it leaves a phantom behind. `networking.primaryIPAddress` is
computed from the network module's **own local `ipInterfaces` binding**, not
from `config.networking.interfaces`
(`nixos/lib/testing/network.nix:59-61`), so forcing the option the module wrote
does not change what the module already computed. And every peer's `/etc/hosts`
is generated from `primaryIPAddress` plus the shared-VLAN addresses
(`nixos/lib/testing/network.nix:70-110`).

Same probe again, this time with `mkForce`:

```
mike's eth1 addresses    = [ "192.168.1.1" ]          # looks fixed
mike's primaryIPAddress  = "192.168.1.2"              # phantom
/etc/hosts on alpha      192.168.1.1 mike
                         192.168.1.2 mike             # resolves, never answers
                         2001:db8:1::2 mike
```

So `mike` resolves to two addresses: one that belongs to a *different machine*
and one that belongs to nobody. `getent hosts mike` will happily return either.

## The correct fix

```nix
virtualisation.interfaces.eth1 = { vlan = 1; assignIP = false; };
networking.interfaces.eth1.ipv4.addresses = [ { address = "10.1.0.50"; prefixLength = 24; } ];
networking.primaryIPAddress = lib.mkForce "10.1.0.50";
```

Note which `mkForce` survives. `assignIP = false` leaves the framework's
`ipInterfaces` list empty, but `networking.primaryIPAddress` is still *defined*
by the framework — as `""` (`nixos/lib/testing/network.nix:59-60`, the
`optionalString` else-branch). A plain definition is therefore a conflict, not
an override. Without `mkForce` you get:

```
error: The option `nodes.browser.networking.primaryIPAddress' has conflicting definition values:
       - In `nixos/lib/testing/network.nix, via option extraBaseModules': ""
       - In `the argument that was passed to pkgs.runNixOSTest': "10.1.0.50"
```

`mkForce` on `primaryIPAddress` = required. `mkForce` on
`networking.interfaces.*` = the wrong fix for Trap 2. `mkTopology` does the
former and never the latter, and emits assertions that fail the *evaluation* if
either invariant breaks — one asserting `virtualisation.vlans == []`, one
asserting each topology interface carries exactly one IPv4 address, one
asserting `primaryIPAddress` is the address you declared.

### What upstream does not do

`assignIP` exists and is correct, but it is effectively undiscoverable. In the
whole nixpkgs tree it appears in **exactly one test** —
`nixos/tests/systemd-initrd-bridge.nix:31` and `:35` — where it is set to
`false` with no comment, next to a bare
`networking.primaryIPAddress = lib.mkForce "192.168.1.${nodeNumber}"` on line 27
that silently encodes both of the facts above. The option's own docstring
(`guest-networking-options.nix:29-32`) says only "using the same scheme as
`virtualisation.vlans`" and never states that the scheme is rank-based, or that
turning it off blanks `primaryIPAddress`. There is no topology helper upstream;
all 56 in-tree tests that use `virtualisation.vlans` open-code their addressing.

## Trap 4 — a filtering test on ONE subnet proves nothing

If the guest and the destination sit on the same subnet, the guest ARPs the
destination directly. The packet never enters the `FORWARD` hook, your filter
never runs, and a test asserting "blocked request fails / allowed request
succeeds" passes for reasons that have nothing to do with the rule under test.
The inverse is worse: a "blocked" request that *succeeds* looks like a filter
bug when in fact the traffic bypassed the router.

This is not hypothetical: a forward-chain counter reading **zero packets**
while a supposedly-blocked request completes normally is the signature. The
rule is fine. The topology is not.

Two defences, both in this recipe:

1. **Put them on different subnets** and assert it. The example does
   `ip route get <destination>` on the guest and requires the answer to contain
   `via <router>` — if the destination is ever on-link, that assertion fails
   before any filtering claim is made.
2. **Count what reaches the hook.** `fixtures.forwardCounter` installs a
   counting base chain on the `forward` hook and gives you `<name>-count` and
   `<name>-reset` on `PATH`. A blocked-traffic subtest must assert *both* that
   the request failed *and* that the counter incremented; otherwise it is
   indistinguishable from an ARP-level bypass.

Two implementation notes on the counter:

- It is its own `nf_tables` table at `priority -300` with `policy accept`, loaded
  by a dedicated oneshot — **not** through `networking.firewall.extraCommands`.
  nixpkgs hard-asserts that option is empty under the nftables backend
  (`nixos/modules/services/networking/firewall-nftables.nix:65-66`:
  `assertion = cfg.extraCommands == ""`), so an `extraCommands`-based counter
  would make the recipe unusable in exactly the tests that most need it. A
  separate low-priority base chain counts and falls through, so it works with
  the iptables backend, the nftables backend, or `firewall.enable = false`.
- `packets` is a reserved word in the nft grammar. Naming the counter object
  `packets` yields
  `Error: syntax error, unexpected packets, expecting string or last` at load
  time and the oneshot fails; the object is called `hits`.

## Trap 5 — a secrets stub must use the REAL path convention, and seeding is an ordering problem

Two independent ways to write a green test around a secret that is broken in
production.

**Wrong path.** Stub the provider at a path of your own choosing and the module
under test reads *your* path in the test and the *real* provider's path on the
deployment. `fixtures.secretsStub` defaults `runDir` to `/run/agenix` and
derives `path = "${runDir}/${name}"` from the secret's attribute name — the same
default the real module set uses. Change `runDir` to match whatever provider you
actually run; do not change the shape.

**Wrong ordering.** Creating the file is not the hard part; guaranteeing it
exists *before* its consumer starts is. The stub emits a `Type=oneshot` +
`RemainAfterExit=true` seeder that is `Before=` every unit named in `consumers`,
and injects `After=`/`Requires=` on the consumer side as well. The redundancy is
deliberate: `Before=` only orders units inside one transaction, so a consumer
you `systemctl start` mid-test — after a `stop`, or a socket-activated one —
would otherwise race. The example test proves this by stopping both units,
deleting the secret, starting only the consumer, and asserting the secret is
back.

`systemd.tmpfiles.settings` is the right upstream primitive for *directories*
and empty files here, but not for this: its `f` argument cannot contain
newlines, it only writes when the file is absent, and it runs once at boot, so
it cannot re-seed a `/run` secret that a test deliberately removed.

Secret contents are written into the store by this fixture. It is a test
fixture. Never point it at a real secret.

## Trap 6 — test the portable recipe, NOT your adapter

State it plainly, because it is the single most common way a test in a
recipe-plus-adapter layout stops evaluating.

When a private module becomes a thin adapter that does
`imports = [ (basePath + "/vendor/recipes/modules/<name>") ]` — where `basePath`
is whatever argument your repo threads the checkout root through — that path is
consumed **in `imports`**. It therefore has to arrive as a `specialArg`;
supplying it through a node's `_module.args` is infinite recursion, because
`config` would depend on `imports`. A test that imports the adapter and forgets
`node.specialArgs.basePath` does not fail an assertion — it fails to evaluate,
which is why it tends to go unnoticed until someone runs the whole `checks` set.

It is easy for this to go unnoticed at scale: only the handful of tests that
happen to set the specialArg keep working, while every other adapter-importing
test silently stops evaluating.

The fix is not to plumb the specialArg everywhere. It is to import the recipe
directly:

```nix
# not:  imports = [ ../modules/setup/unlock-ssh.nix ];   # adapter, needs a specialArg
imports = [ ../vendor/recipes/modules/remote-luks-unlock ];   # the recipe itself
```

The recipe owns the option surface; the adapter only pins fleet values on top.
Testing the recipe tests the thing that is actually portable, keeps the test
free of repo-root path plumbing, and means the test still passes for anyone who
vendors the recipe without your adapter. Use `node.specialArgs` only when the
adapter itself is the subject under test.

## API

### `mkTopology { subnets, hosts, defaultPrefixLength ? 24 }`

`subnets.<name>`:

| key             | default              | meaning |
|-----------------|----------------------|---------|
| `vlan`          | *(required)*         | VLAN id, 1–255. 0 would collide with the VM's own `eth0`; `nixos/lib/qemu-common.nix` throws above 255. |
| `prefix`        | `"10.<vlan>.0"`      | First three octets. Deliberately off `192.168.*` so a stray auto-assigned address is visibly foreign. |
| `prefixLength`  | `defaultPrefixLength`| |
| `prefix6`       | `null`               | e.g. `"fd00:1::"`; enables IPv6 on this subnet. |
| `prefixLength6` | `64`                 | |
| `interface`     | `"eth<vlan>"`        | Same name on every host, so rules and scripts can name it without knowing a host's interface ordering. |

`hosts.<name>`:

| key         | default                 | meaning |
|-------------|-------------------------|---------|
| `addresses` | *(required)*            | `{ <subnet> = <last octet 1–254>; }` |
| `via`       | *(none)*                | Default route through that host, on the first subnet they share. |
| `forward`   | `false`                 | Sets `net.ipv4.ip_forward` and `net.ipv6.conf.all.forwarding`. |
| `primary`   | alphabetically first    | Which subnet's address becomes `networking.primaryIPAddress`. |

Unknown keys are rejected with a message that points at the likely typo
(`host 'x': unknown key 'lan' -- did you mean addresses.lan?`), as are duplicate
vlans, duplicate octets within a subnet, octets out of range, `via` pointing at
a host that shares no subnet, and `interface = "eth0"`.

Returns:

```
topo.nodes.<host>            NixOS module to import into that node
topo.ip.<host>.<subnet>      "10.1.0.50"
topo.ip6.<host>.<subnet>     only for subnets declaring prefix6
topo.iface.<subnet>          "eth1"
topo.vlan.<subnet>           1
topo.cidr.<subnet>           "10.1.0.0/24"
topo.alias.<host>.<subnet>   "origin-uplink"  (resolvable on every node)
topo.subnets / topo.hosts    normalised inputs
```

**Why the aliases exist.** The framework's `/etc/hosts` only ever publishes each
node's *primary* address plus addresses on VLANs the two nodes share
(`nixos/lib/testing/network.nix:70-110`), and `mkTopology` leaves
`virtualisation.vlans` empty, so the shared-VLAN half contributes nothing. A
multi-homed node's bare hostname therefore resolves to one leg only, and a peer
on the other leg would hang. `mkTopology` writes its own `networking.extraHosts`
so `<host>-<subnet>` always resolves to the right leg.

### Fixtures

| fixture | signature |
|---------|-----------|
| `fixtures.optionStub` | `{ "home.programs" = {}; "visual" = false; } -> module` — declares foreign option paths as `types.anything` so a module under test can read an option tree whose real provider is not imported. |
| `fixtures.secretsStub` | `{ namespace ? "age", runDir ? "/run/agenix", contents ? {}, defaultContent ? …, consumers ? [], unitName ? "test-secrets-seed" } -> module` |
| `fixtures.httpEcho` | `{ name ? "http-echo", port ? 8080, listen ? "0.0.0.0" } -> module` — answers with the client's source address, so a test can assert *who* the far end saw, not merely that a request succeeded. `DynamicUser`. |
| `fixtures.forwardCounter` | `{ name ? "topo_fwd", family ? "inet", priority ? -300, match ? "" } -> module` — plus `<name>-count` / `<name>-reset` on `PATH`. |

## Running the worked example

`examples.filteringRouter` is a complete three-node test — guest, NAT router,
origin — that exercises every trap above. Node names are chosen adversarially:
`browser < gateway < origin`, so the framework would have ranked them 1/2/3 and
handed out `192.168.1.1`–`.3`; the first subtest asserts no `192.168.*` address
exists anywhere.

```sh
nix build --impure --expr '
  let pkgs = import <nixpkgs> {}; in
  (import ./lib/nixos-test-topology).examples.filteringRouter { inherit pkgs; }'
```

Nine subtests, 36.6 s of test script on top of VM boot:

1. no phantom framework addresses anywhere
2. each topology interface has exactly one address
3. addresses are the ones the topology declared
4. guest and destination are on different subnets (`ip route get` must say `via`)
5. allowed traffic transits the FORWARD hook and is NATed (origin sees the
   router's uplink address; counter > 0)
6. blocked traffic is dropped **at** the forward hook, not merely absent
   (request fails **and** counter > 0)
7. per-leg host aliases resolve
8. stub secret landed at the real provider's default path
9. consumer cannot start before the seeder

Subtest 6 is the one worth copying. `browser.fail(curl …)` on its own is
satisfied by a typo in an address, a missing route, a dead service, or an actual
`drop` rule. Pairing it with a non-zero forward-hook counter narrows it to one.

## Caveats

- Interface names default to `eth<vlan>`, so a subnet on vlan ≥ 10 gets `eth10`,
  which sorts before `eth2`. That changes the QEMU NIC slot order but not the
  result: udev renames by MAC, and the MAC is derived from `(vlan, nodeNumber)`
  only (`nixos/lib/qemu-common.nix`, `qemuNicMac`; rules built at
  `nixos/lib/testing/network.nix:136-145`). Pass `interface` explicitly if you
  want a different naming scheme.
- `mkTopology` and `virtualisation.vlans` are mutually exclusive by design. If
  you mix them, `virtualisation.allInterfaces` merges both
  (`guest-networking-options.nix:107`) and upstream's own conflicting-name
  assertion (`:123-135`) may or may not catch it first — the emitted
  `virtualisation.vlans == []` assertion will.
- The nodes this generates use scripted networking (`useDHCP = false`,
  `networking.interfaces.*`). For a networkd- or ifstate-driven test, take
  `topo.ip` / `topo.iface` and write the addresses yourself; the
  `virtualisation.interfaces … assignIP = false` half still applies unchanged.
- IPv6 is opt-in per subnet via `prefix6`. Without it, `primaryIPv6Address`
  stays `""`, which makes the framework emit a `/etc/hosts` line consisting of a
  space and a hostname. glibc ignores it; it is cosmetic.
