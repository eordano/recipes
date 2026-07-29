# ip-cidr-set-exclude

Compute **allow-networks minus deny-networks** as an explicit, minimal CIDR
list — at Nix build time — and splat the result straight into WireGuard's
`AllowedIPs`.

## The problem

For split-tunnel routing you often want "send everything through the tunnel
**except** these ranges": exclude the LAN, RFC1918 space, a management subnet,
or an overlay-mesh range so that local and mesh traffic stays off the tunnel.

WireGuard has no way to express that directly. `AllowedIPs` is an *inclusion*
list with no exclude/negate syntax. To punch a hole in a broad route like
`0.0.0.0/0` you must instead list the **complementary set** of ranges that
tile neatly *around* the hole:

```
0.0.0.0/0  minus  10.0.0.0/8
  = 0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, ...
```

Working that arithmetic out by hand — and re-doing it every time the deny list
changes — is exactly the kind of thing that ends with a subtly wrong prefix and
a routing leak. This recipe derives it deterministically.

## The insight

The fiddly part (splitting a network around an excluded subnet) is already
solved by Python's standard-library `ipaddress` module — `address_exclude`
returns the minimal set of prefixes covering `A \ B`. So the subtraction runs
in a tiny **build-time** derivation (a `runCommand` invoking Python), and the
Nix side just feeds it comma-joined inputs and parses the one-line output back
into a list. No runtime dependency, no Python on the target host — the CIDR
list is baked into the closure.

## Usage

Import it with a `pkgs`:

```nix
let tools = import ./ip-cidr-set-exclude { inherit pkgs; };
in {
  networking.wireguard.interfaces.wg0.peers = [{
    # ... publicKey, endpoint ...
    allowedIPs = tools.buildIpList
      "0.0.0.0/0,::/0"                                   # allow: everything
      "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8"; # deny: private + loopback
  }];
}
```

Both arguments accept **either** a comma-joined string **or** a Nix list of
strings, so this is equivalent:

```nix
tools.buildIpList
  [ "0.0.0.0/0" "::/0" ]
  [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" ];
```

`buildIpList` returns a `[ "cidr" "cidr" ... ]` list. Bare addresses are
widened to `/32` (IPv4) or `/128` (IPv6). IPv4 and IPv6 are handled
independently and IPv4 ranges come first.

### As an overlay

Drop the directory onto your overlay list to expose `pkgs.ip-mask` (a CLI) and
`pkgs.buildIpList`:

```nix
nixpkgs.overlays = [
  (final: prev: import ./ip-cidr-set-exclude { pkgs = prev; })
];
```

### As a CLI

`pkgs.ip-mask` wraps the same logic for interactive use:

```
$ ip-mask 0.0.0.0/0 10.0.0.0/8,192.168.0.0/16
0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, ...
```

Run it with no arguments and it prompts for the allow and deny lists.

## Caveats and traps

- **Trailing newline.** The Python step prints one trailing `\n`. `buildIpList`
  strips it *before* splitting on `", "` — if you reimplement the parse, do the
  same, otherwise the last element carries a `\n` and WireGuard rejects the
  whole `AllowedIPs` line.
- **`split` returns interleaved groups.** `builtins.split ", "` yields the
  matched separators as nested lists between the strings; the final `filter`
  keeps only the string elements. Don't drop it.
- **Partial overlaps are enumerated host-by-host.** When a deny range only
  *partially* overlaps an allow range (rather than being fully contained in
  it), the fallback walks individual host addresses and emits `/32`s. Keep
  partial overlaps small — don't straddle a huge allow range with a deny range
  drawn from a different block, or you'll generate an enormous list and a slow
  build. In practice, keep every deny entry a subnet of some allow entry (the
  common case: carving private blocks out of `0.0.0.0/0`) and this path never
  triggers.
- **Empty result fails the build.** If the deny list swallows the entire allow
  list, the Python step exits non-zero (`No IPs are allowed`) and the
  derivation fails — a loud failure instead of a silently empty `AllowedIPs`.
- **Build-time only.** The subtraction is computed when the config is built, so
  changing the deny list means a rebuild. That's the point: the routing table
  is pinned in the closure, not recomputed on the host.

## Files

- `default.nix` — the overlay/helper (`ip-mask` CLI + `buildIpList` function),
  with the Python subtraction step inlined.
