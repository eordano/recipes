# mesh-overlay-address-identity

Keep a declarative *name → overlay address* map honest against the live mesh, and
repair the control plane when a node re-registers under a new address. Two tools —
a pre-commit reconciler and a coordination-server surgery script — because they are
two halves of the same failure.

Written against [headscale](https://headscale.net/) 0.29 + Tailscale clients, but
nothing here is headscale-specific beyond the sqlite schema (`nodes` table with
`id`, `given_name`, `ipv4`, `ipv6`), which the tool verifies before it writes.

## The problem

Once a mesh has more than a handful of machines, the overlay address stops being an
implementation detail. It ends up hard-coded in ACL host groups, exit-node DNS
resolvers, `/etc/hosts`, ssh aliases, DERP maps, monitoring targets, firewall
allowlists. So you write it down once — a Nix file mapping machine name to
address — and derive all of that from it.

That map is a *claim about the world*, and the world moves without asking:

- A machine gets reinstalled, its agent state is wiped, and it registers again with
  a **fresh machine key**. The control plane keys nodes by machine key, so this is a
  brand new node. The hostname collides with the old record, so the server
  disambiguates by suffixing the given-name: `builder` → `builder-1`. You now have
  **two rows for one machine**: an offline shadow squatting the canonical address,
  and the live node on a fresh address that nothing in your fleet points at.
- Addresses get **recycled**. Delete a machine, enroll a phone six months later, and
  the phone can land on the retired machine's address — which your ACLs still trust.
- Someone enrolls a device and never touches the map. The map is now quietly
  incomplete, and stays that way until something breaks.

Nothing in the stack tells you. `tailscale status` is happy, the control plane is
happy, and the map file — the thing every consumer trusts — is wrong.

## Why the repair is a database edit, not an API call

The obvious fix ("delete the stale node and let the live one re-register onto the
free address") does not work with the default allocation strategy. nixpkgs documents
it exactly, in the headscale module:

> `nixos/modules/services/networking/headscale.nix:143-155` —
> `settings.prefixes.allocation`, default `"sequential"`:
> *"sequential (default): assigns the next free IP from the previous given IP."*

**From the previous given IP.** The allocator walks forward from the last address it
handed out; freed addresses behind that cursor are not revisited. Deleting a node
does not put its address back at the front of the queue — it hands the re-registering
node the next never-used address, one higher than before. Re-registering can never
reclaim a canonical address; it can only burn another one.

Nor is there a verb for it. The whole node surface of the 0.29 CLI is
`approve-routes`, `backfillips`, `delete`, `expire`, `list`, `list-routes`,
`rename`, `tag`. You can rename a node; you cannot place it. `backfillips` only
fills in addresses that are *missing*, and it allocates them from the same
forward-walking cursor, so it cannot be steered either.

So the only way to put the live node back on the address the rest of the fleet pins
is to update the row. That is what `mesh-node-reassociate` does — carefully.

What nixpkgs gives you: a service unit and a settings freeform
(`nixos/modules/services/networking/headscale.nix:727` is the whole systemd unit,
`:232` the sqlite path). What it does not give you: any node-lifecycle or database
maintenance surface, and no notion at all that your repository holds a map that is
supposed to agree with that database.

## Tool 1 — `mesh-address-drift-check` (pre-commit reconciler)

Runs in the repository that owns the map, on every commit, and compares the map
against the local agent's netmap. Four outcomes:

| Live state | Verdict |
| --- | --- |
| address in map, name matches (or matches its alias) | pass |
| address in map, **different name** | **block** — address reuse or a rogue registration |
| address unknown, name looks like `<known-name>-<n>` | **block** — re-registration duplicate, prints the `mesh-node-reassociate` command to fix it |
| address unknown, ordinary name | append to the map above the marker, `git add`, pass |

### Traps encoded in it

- **Compare by address, not by name.** The dangerous case is one address held by an
  unexpected name. A name-keyed comparison walks the map and asks "is this machine
  still at this address" — it never sees the phone that inherited a retired
  machine's address, because that address is not missing, it is *occupied by someone
  else*. The check builds the reverse index and iterates over live nodes.
- **Never block a commit because the network is down.** Missing agent, missing
  `nix`, daemon down, unparseable JSON, timeout → print one line and `exit 0`. A
  hook that fails offline gets deleted within a week, and then you have no check at
  all. Only *disagreement* is fatal; *ignorance* is not.
- **Absence is not drift.** Netmaps are ACL-scoped: a machine you are not allowed to
  talk to simply is not in your netmap. Map entries you cannot see are counted in a
  note, never flagged. This is why the check is one-directional.
- **The `-1` suffix is the duplicate signature.** A live node named `<known>-<n>` on
  an address that is not in the map is not a new device — it is a machine you already
  track, back with a fresh key. Auto-adding it would enshrine the wrong address in
  the map and leave the canonical one stranded forever. It blocks instead and prints
  the exact re-association command. (Consequence: a genuinely new device whose name
  ends in `-<n>` and shares a base with a tracked machine must be added to the map by
  hand. That is the intended trade.)
- **The marker is an ordering constraint, not decoration.** Auto-added entries are
  inserted on the line *above* the marker comment, so the marker must be the last
  line of the block new devices belong in. Without a marker the tool refuses to guess
  and prints the entries for you to place. Insert-above also keeps the block's
  closing brace intact without parsing Nix.
- **Refuse to auto-edit a dirty map file.** `git add <file>` stages the *whole* file.
  If the map already has unstaged edits, appending and staging would sweep the
  author's half-finished work into this commit. When the file is dirty the tool
  reports the missing devices and blocks instead of touching it.
- **Evaluate the map, don't parse it.** It reads the map with `nix eval --json -f`,
  so the map may be `rec`, may compose sub-attrsets, may derive entries from other
  files — the check sees the same values your modules see, not a regex's guess. The
  price is a dependency on `nix` being on `PATH`, which is a skip, not a failure.
- **Use the DNS label, not `HostName`.** `HostName` is what the machine calls itself
  locally and drifts independently of the control plane. The first label of `DNSName`
  is the given-name the control plane actually serves — that is what your ACLs and
  MagicDNS resolve, so that is what the map must agree with. Comparison is
  lowercased; intentional divergences (rename lag, historical names) go in the alias
  table rather than weakening the check.

## Tool 2 — `mesh-node-reassociate` (control-plane surgery)

Run as root on the coordination host. Selects one live node, optionally deletes the
shadow record holding the target address, and moves the live node onto it:

```console
# mesh-node-reassociate \
    --from-name=builder-1 --to-ip=100.100.100.11 --to-name=builder \
    --delete-conflict --steal-ipv6 \
    --node-ssh='root@192.0.2.10 -p 22'
```

`--dry-run` prints the plan and the exact SQL and changes nothing; `--list` dumps
the node table.

### Traps encoded in it

- **Editing a live database is the whole risk.** The sequence is fixed: verify the
  schema → resolve exactly one source node → refuse ambiguity → **stop the service**
  → snapshot → single `BEGIN IMMEDIATE` transaction → start → health-poll → post-check
  → only then touch the node. Nothing is written while the server is running: it
  caches state in memory and would happily overwrite your edit on its next flush.
- **Snapshot *after* the stop, and use `.backup`.** `cp` of the main database file
  while the server is running misses everything still in the `-wal` sidecar, so the
  "backup" can be a state that never existed. `sqlite3 .backup` after the service is
  stopped is a consistent snapshot, and its path is printed in every failure message.
- **Refuse an unknown schema.** Before anything else it checks that `nodes` has
  `id`, `given_name`, `ipv4`, `ipv6`. Older coordination servers stored addresses
  serialised in a single column under a different table name; on those, a blind
  `UPDATE ... SET ipv4` writes a column that does not exist (or, worse, exists with
  different semantics). Fail loudly with the column list instead.
- **Constrain the target address.** `addressPrefixes` restricts what `--to-ip` will
  accept. A typo outside the overlay range is accepted by sqlite without complaint
  and then served to every client in the netmap.
- **Fail closed on a conflict.** If another row holds the target address or name, the
  tool stops and describes it; you must pass `--delete-conflict` to remove the shadow.
  Two rows sharing an address is a state the coordination server does not expect.
- **`--steal-ipv6` exists for a reason.** IPv6 is allocated from the same monotonic
  cursor, so the shadow record is holding the canonical v6 address too. Moving only
  the v4 address leaves the node with a v6 nobody references. Take both.
- **Post-check the invariant.** After restart it re-counts holders of the target
  address and aborts (pointing at the backup) unless it is exactly one.
- **The node does not notice.** The client keeps using its old address until its next
  netmap poll. `--node-ssh` restarts the agent over ssh to force it; without it the
  tool tells you the address will be adopted eventually. If the node in question is
  reachable *only* over the mesh, expect to bounce it out-of-band — you have just
  changed the address you were reaching it on.
- **All SQL selectors are validated, not bound.** sqlite3 CLI takes no bind
  parameters, so names and addresses are interpolated into SQL text. Every selector
  (`--from-name` included, not just the write side) is validated against a strict
  character class first.

## Usage

```nix
{
  imports = [ ./mesh-overlay-address-identity ];

  networking.meshAddressIdentity = {
    # The file of record lives in your repository, because the pre-commit hook
    # has to be able to append to it. Import it here so modules can consume it.
    addresses = (import ../mesh-addresses.nix).addresses;
    aliases = (import ../mesh-addresses.nix).aliases;
    ignore = (import ../mesh-addresses.nix).ignore;

    addressPrefixes = [ "100.100." ];

    hostAliases = {
      enable = true;
      domain = "mesh.example.org";
    };

    # On the coordination host only:
    reassociate = {
      enable = true;
      database = "/var/lib/headscale/db.sqlite";
      serviceName = "headscale";
      cli = "headscale";
      nodeRestartCommand = "systemctl restart tailscaled";
    };

    # On machines where you commit:
    driftCheck = {
      enable = true;
      mapGlob = "*mesh-addresses.nix";
      marker = "drift-hook:";
      keys = {
        addresses = "addresses";
        aliases = "aliases";
        ignore = "ignore";
      };
    };
  };
}
```

The map file — any Nix expression that evaluates to the three attributes:

```nix
rec {
  fleet = {
    workstation = "100.100.100.10";
    builder = "100.100.100.11";
  };
  devices = {
    phone = "100.100.100.20";
    # drift-hook: keep this marker last; auto-added devices land above it.
  };

  addresses = fleet // devices;

  # Live given-names that intentionally differ from the canonical name.
  aliases = { builder = "build-box"; };

  # Known-junk registrations pending deletion on the coordination host.
  ignore = [ "100.100.100.90" ];
}
```

Wire the checker into git (per clone — hooks are not tracked):

```sh
printf '#!/bin/sh\nexec mesh-address-drift-check\n' > "$(git rev-parse --git-dir)/hooks/pre-commit"
chmod +x "$(git rev-parse --git-dir)/hooks/pre-commit"
```

Exercise it against canned state without committing:

```sh
mesh-address-drift-check --status-file ./saved-status.json   # or MESH_DRIFT_STATUS_FILE=
mesh-address-drift-check --no-auto-add                       # report, never edit
```

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `addresses` | `{}` | Canonical name → overlay address. The single source of truth. |
| `aliases` | `{}` | Canonical name → the given-name the control plane actually serves. |
| `ignore` | `[]` | Addresses the checker ignores (junk registrations pending deletion). |
| `addressPrefixes` | `[]` | Prefixes `--to-ip` accepts. Empty = any IPv4. |
| `hostAliases.enable` | `false` | Generate `networking.hosts` from the map. |
| `hostAliases.domain` | `null` | Also emit `<name>.<domain>`. |
| `reassociate.enable` | `false` | Install the surgery tool (coordination host). |
| `reassociate.database` | `/var/lib/headscale/db.sqlite` | Control-plane sqlite database. |
| `reassociate.serviceName` | `headscale` | Unit stopped around the edit. |
| `reassociate.cli` | `headscale` | Health probe, invoked as `<cli> nodes list`. |
| `reassociate.nodeRestartCommand` | `systemctl restart tailscaled` | Run on the node to force a re-poll. |
| `driftCheck.enable` | `false` | Install the reconciler. |
| `driftCheck.mapGlob` | `*mesh-addresses.nix` | `git ls-files` pattern locating the map (must match one file). |
| `driftCheck.marker` | `drift-hook:` | Marker comment; entries are inserted above it. |
| `driftCheck.overlayPrefix` | `100.` | Addresses considered overlay addresses in the netmap. |
| `driftCheck.keys.*` | `addresses` / `aliases` / `ignore` | Attribute names inside the map file. |

Two assertions guard the map itself: no address may be claimed by two names (that
is exactly the state the checker could not distinguish from a rename), and every
alias must name a machine that exists in `addresses`.

## Caveats

- `mesh-node-reassociate` needs root on the coordination host and briefly stops the
  coordination service. Existing WireGuard sessions survive that; new registrations
  and netmap updates pause for a second or two.
- The checker only sees what *this* machine's netmap shows. Run it where your netmap
  is widest, and cross-check against the coordination server's node list when a
  result surprises you.
- The `-<n>` duplicate heuristic matches the disambiguation suffix scheme used by
  headscale-style servers. If your control plane disambiguates differently, that
  branch simply never fires — the address still lands in the "unknown" bucket.
- All addresses in this README are documentation examples, not a real mesh.
