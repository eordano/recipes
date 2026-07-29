#!/usr/bin/env python3
"""Reconcile a declarative mesh-address map against the live overlay network.

Designed to run as a git pre-commit hook in the repository that owns the map.

  - No overlay agent / no nix / offline: exit 0 silently. A check that blocks
    commits when the network is down gets uninstalled within a week.
  - Live address is in the map under the expected name: fine.
  - Live address is in the map under a different name: BLOCK. This is address
    reuse (a retired machine's address handed to a phone) or a rogue
    registration, and it is the only thing here that is unambiguously wrong.
  - Live name looks like "<known-name>-<n>": BLOCK with a re-association hint.
    That suffix is how a coordination server disambiguates a node that came
    back with a fresh machine key, i.e. a duplicate of a machine already in
    the map, now squatting a fresh address.
  - Live address not in the map at all: append it above the marker line,
    stage the file, let the commit through. Review it in the diff.
  - Map entries not visible locally are only counted: netmaps are ACL-scoped,
    so absence is not drift.

The map is any Nix file evaluating to an attrset with an address table, an
optional alias table (canonical name -> the name the control plane actually
serves) and an optional ignore list. Attribute names are configurable.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import date

TAG = "[mesh-drift]"


def run(cmd, timeout=15):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def skip(msg):
    print(f"{TAG} skipped: {msg}")
    sys.exit(0)


def parse_args(argv):
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--map", help="path to the map file (default: discover with --map-glob)")
    p.add_argument("--map-glob", default="*mesh-addresses.nix",
                   help="git ls-files pattern used to find the map (must match exactly one file)")
    p.add_argument("--key-addresses", default="addresses",
                   help="attribute holding name -> overlay address")
    p.add_argument("--key-aliases", default="aliases",
                   help="attribute holding canonical name -> live control-plane name")
    p.add_argument("--key-ignore", default="ignore",
                   help="attribute holding addresses to ignore entirely")
    p.add_argument("--marker", default="drift-hook:",
                   help="marker comment; auto-added entries are inserted above it")
    p.add_argument("--indent", default="    ", help="indent used for auto-added entries")
    p.add_argument("--overlay-prefix", default="100.",
                   help="only addresses starting with this are considered overlay addresses")
    p.add_argument("--status-cmd", default="tailscale status --json",
                   help="command emitting the live netmap as JSON")
    p.add_argument("--status-file", default=os.environ.get("MESH_DRIFT_STATUS_FILE"),
                   help="read the netmap JSON from a file instead (for testing)")
    p.add_argument("--no-auto-add", action="store_true",
                   help="report unknown devices instead of appending them to the map")
    return p.parse_args(argv)


def live_nodes(args):
    """address -> live name, from the local agent's view of the netmap."""
    if args.status_file:
        raw = open(args.status_file).read()
    else:
        cmd = args.status_cmd.split()
        try:
            p = run(cmd, timeout=5)
        except FileNotFoundError:
            skip(f"{cmd[0]} not on PATH")
        except subprocess.TimeoutExpired:
            skip(f"{cmd[0]} timed out")
        if p.returncode != 0:
            skip(f"{cmd[0]} failed (agent down?)")
        raw = p.stdout
    try:
        status = json.loads(raw)
    except json.JSONDecodeError:
        skip("unparseable netmap JSON")

    nodes = [status.get("Self") or {}] + list((status.get("Peer") or {}).values())
    live = {}
    for n in nodes:
        ips = [i for i in (n.get("TailscaleIPs") or []) if i.startswith(args.overlay_prefix)]
        if not ips:
            continue
        # The DNS label is the control plane's given-name; HostName is whatever
        # the machine calls itself locally and drifts independently.
        dns = (n.get("DNSName") or "").rstrip(".")
        name = dns.split(".")[0] if dns else (n.get("HostName") or "?")
        live[ips[0]] = name.lower()
    return live


def load_map(map_path, args):
    try:
        p = run(["nix", "eval", "--json", "-f", map_path])
    except FileNotFoundError:
        skip("nix not on PATH")
    if p.returncode != 0:
        print(f"{TAG} ERROR: nix eval of {map_path} failed:\n{p.stderr.strip()}")
        sys.exit(1)
    m = json.loads(p.stdout)
    if args.key_addresses not in m:
        print(f"{TAG} ERROR: {map_path} has no {args.key_addresses!r} attribute")
        sys.exit(1)
    return (m[args.key_addresses],
            m.get(args.key_aliases, {}) or {},
            set(m.get(args.key_ignore, []) or []))


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)

    try:
        toplevel = run(["git", "rev-parse", "--show-toplevel"]).stdout.strip()
    except Exception:
        sys.exit(0)
    if not toplevel:
        sys.exit(0)

    if args.map:
        map_rel = os.path.relpath(os.path.abspath(args.map), toplevel)
    else:
        ls = run(["git", "-C", toplevel, "ls-files", "--", args.map_glob])
        found = ls.stdout.strip().splitlines()
        if len(found) != 1:
            skip(f"expected exactly one tracked {args.map_glob}, found {len(found)}")
        map_rel = found[0]
    map_path = os.path.join(toplevel, map_rel)

    live = live_nodes(args)
    addresses, aliases, ignore = load_map(map_path, args)

    by_addr = {addr: name for name, addr in addresses.items()}
    # live name (lowercased) -> the canonical name and address it belongs to
    known = {n.lower(): (n, a) for n, a in addresses.items()}
    for canon, alias in aliases.items():
        if canon in addresses:
            known.setdefault(alias.lower(), (canon, addresses[canon]))

    mismatches = []
    duplicates = []
    unknown = {}
    for addr, name in sorted(live.items()):
        if addr in ignore:
            continue
        canonical = by_addr.get(addr)
        if canonical is not None:
            if name not in (canonical.lower(), aliases.get(canonical, "").lower()):
                mismatches.append((addr, canonical, name))
            continue
        # Unknown address. Before treating it as a new device, check for the
        # "<name>-<n>" shape: that is a re-registration of a machine we already
        # track, not a new machine.
        m = re.fullmatch(r"(.+?)-(\d+)", name)
        if m and m.group(1) in known:
            canon, canon_addr = known[m.group(1)]
            duplicates.append((addr, name, canon, canon_addr))
        else:
            unknown[addr] = name

    unseen = sorted(set(addresses.values()) - set(live) - ignore)

    if duplicates:
        print(f"{TAG} re-registration duplicates on the overlay:")
        for addr, name, canon, canon_addr in duplicates:
            print(f"  {name} at {addr} looks like a second registration of {canon!r} ({canon_addr})")
        print(f"{TAG} the machine came back with a fresh key and was given a new")
        print(f"{TAG} address; its canonical one is stranded on the offline record.")
        print(f"{TAG} Re-point it on the coordination host, e.g.:")
        for addr, name, canon, canon_addr in duplicates:
            print(f"  mesh-node-reassociate --from-name={name} --to-ip={canon_addr} "
                  f"--to-name={canon} --delete-conflict --steal-ipv6")
        sys.exit(1)

    if mismatches:
        print(f"{TAG} name mismatch between {map_rel} and the live overlay:")
        for addr, want, got in mismatches:
            print(f"  {addr}: map says {want!r}, live node is {got!r}")
        print(f"{TAG} if the live name is right, fix the map (or its alias table);")
        print(f"{TAG} if the node is rogue, remove it on the coordination host.")
        sys.exit(1)

    if unknown:
        if args.no_auto_add:
            print(f"{TAG} live overlay has devices missing from {map_rel}:")
            for addr, name in unknown.items():
                print(f"  {name} = {addr}")
            sys.exit(1)
        # `git add` stages the whole file. If the map already has unstaged
        # edits, appending and staging would sweep the author's half-finished
        # work into this commit — refuse instead.
        dirty = run(["git", "-C", toplevel, "diff", "--name-only", "--", map_rel]).stdout.strip()
        if dirty:
            print(f"{TAG} live overlay has devices missing from {map_rel}:")
            for addr, name in unknown.items():
                print(f"  {name} = {addr}")
            print(f"{TAG} the file has unstaged edits, so nothing was auto-added; add them yourself.")
            sys.exit(1)
        lines = open(map_path).readlines()
        marker = next((i for i, ln in enumerate(lines) if args.marker in ln), None)
        if marker is None:
            print(f"{TAG} {args.marker!r} marker missing from {map_rel}; add these entries manually:")
            for addr, name in unknown.items():
                print(f"  {name} = {addr}")
            sys.exit(1)
        for addr, name in unknown.items():
            attr = name if re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_'-]*", name) else f'"{name}"'
            lines.insert(marker, f'{args.indent}{attr} = "{addr}"; # auto-added {date.today().isoformat()}\n')
            marker += 1
            print(f"{TAG} added {name} = {addr} to {map_rel}")
        open(map_path, "w").writelines(lines)
        subprocess.run(["git", "-C", toplevel, "add", "--", map_rel], check=True)
        print(f"{TAG} staged; review the entry in your diff (canonical name, comments).")

    if unseen:
        print(f"{TAG} note: {len(unseen)} map entries not visible from this host's netmap (fine).")


if __name__ == "__main__":
    main()
