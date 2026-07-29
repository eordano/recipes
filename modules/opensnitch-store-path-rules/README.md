# opensnitch-store-path-rules

Per-process egress rules for [OpenSnitch](https://github.com/evilsocket/opensnitch),
written as Nix expressions, that **keep matching after the package is rebuilt**.

OpenSnitch identifies a process by its absolute executable path. On NixOS that
path is content-addressed — `/nix/store/<32-char-hash>-curl-8.14.1/bin/curl` —
and the hash changes on every upgrade, every patch, every stdenv bump. A rule
that names the path you have today is a rule that stops matching tomorrow, at
which point the program either prompts forever or (with
`DefaultAction = "deny"`) has its connections silently dropped.

This module generates rules that match the *shape* of a store path instead of
one instance of it, and lints the patterns so the classic mistakes fail at
evaluation instead of at 03:00 when a backup stops uploading.

Ships with a NixOS VM test (`test.nix`) that runs opensnitchd under
`DefaultAction = "deny"` with the eBPF process monitor and proves, over real
HTTP requests between two VMs, that the generated rule keeps allowing the target
binary across three rebuilds while a hand-written literal-path rule stops
matching after the first one. See [Tests](#tests).

## The problem

`services.opensnitch.rules` in nixpkgs is a freeform JSON passthrough. Its type
is a submodule with `freeformType = format.type`
(`nixos/modules/services/security/opensnitch.nix:52`), each rule is serialised
with `pkgs.writeText "rule" (builtins.toJSON cfg)` (line 13) and symlinked into
`/var/lib/opensnitch/rules`. Upstream takes no position at all on what goes into
`operator.data`, and the option's own example (lines 33–41) does the thing that
breaks:

```nix
"operator" = {
  "type" = "simple";
  "operand" = "process.path";
  "data" = "${lib.getBin pkgs.tor}/bin/tor";
};
```

That is an *exact* store path. It is not wrong in the sense of being
unmaintainable — Nix will re-interpolate it on the next rebuild — but it has
four consequences nobody reads out of the example:

1. **It only matches if `getBin`/`getExe` returns the path the kernel actually
   execs.** For anything nixpkgs wraps, it does not. See Trap 2.
2. **It pulls the package into the system closure.** The generated rule file
   depends on `pkgs.tor`, so `tor` is now a dependency of your `/etc` and gets
   built and copied to the host — even if you never installed it and only ever
   run it through `nix run`.
3. **It churns.** Every version bump rewrites the rule file, which rewrites the
   `etc` derivation, which is fine — until you notice consequence 4.
4. **It has a live-invalidation window.** `nixos-rebuild switch` installs the
   new rule while the *running* process is still executing from the **old**
   store path. opensnitchd reloads the rules directory on change, the running
   browser no longer matches its own rule, and its next connection is denied.
   The program keeps running and quietly loses the network until it restarts.

A pattern rule has none of the four. It references no package, so the closure is
untouched; it does not change when the package changes, so nothing churns and
there is no invalidation window; and it can be written to cover the wrapper
*and* the payload.

## Traps

### Trap 1 — the mechanism, and exactly how far it goes

Every generated `process.path` operand has `type = "regexp"` and matches on the
components of a store path that are stable across rebuilds:

```
^/nix/store/[0-9a-z]+-tailscale-[^/]*/bin/(\.)?tailscaled(-wrapped)?$
 └ literal ┘└ hash ┘ └ pname ┘└ version ┘└──── payload path ─────┘
```

The hash is the only part that moves; everything else is derivation metadata you
already control. `binaries.<name>` builds that string from `pname`, a version
pattern, and the path inside the output.

**What this buys you:** rules survive `nix flake update`, channel bumps, mass
rebuilds, and `--rebuild`. The generated JSON is a fixed point — it does not
change when the package changes, which also means `nixos-rebuild` produces no
opensnitch diff at all on a normal upgrade.

**What it costs you — and this is the real limit:** the rule authorises a
**class** of store paths, not a specific artifact. Anything on the machine whose
derivation name matches `tailscale-*` and that ships `bin/tailscaled` gets the
same permission, including something a user builds in `nix develop`. Store paths
are unforgeable *addresses*, not *authenticators*, and matching them by shape
gives up the one property that made them exact. If you need the strong version,
use `rules.<name>.processPath` with a pinned store path, accept the churn, and
re-read Trap 1's consequence 4 before you deploy it.

There is no middle ground available: OpenSnitch has no notion of a signature, a
Nix output hash, or an "any path produced by this derivation" predicate. The
choice is *class of paths* or *one path that expires*.

### Trap 2 — wrappers: the binary you name is not the binary that runs

`makeWrapper`/`wrapProgram` move the real ELF to `bin/.NAME-wrapped` and put a
launcher at `bin/NAME`. The launcher `exec`s the payload, so by the time the
socket is created, `/proc/<pid>/exe` points at the **dot-prefixed** file. A rule
written for `bin/NAME` never matches. Worse, `lib.getExe` returns `bin/NAME`, so
the "obvious" declarative rule is wrong in exactly this case.

Hence `wrapped = true`, which widens the leaf to `(\.)?NAME(-wrapped)?` and
covers both. Set it for anything that is wrapped, and expect to be surprised by
what is: GUI apps, Qt apps, anything with `QT_PLUGIN_PATH`, anything with a
`PATH` fixup, Go binaries that need `LD_LIBRARY_PATH`, and CLI tools whose
package adds a `--config` default.

**A real incident.** A recording tool's derivation installs *two* wrapped
binaries — the main one and a secondary uploader. The rule was written for the
main one:

```
^/nix/store/[a-z0-9]+-rec-.*/bin/\.rec-wrapped$
```

The uploader is `bin/.rec-tab-wrapped`, which that regex does not match. It ran,
it produced files, and its uploads were dropped — no error in the tool, no
prompt, just a transfer that never completed. Fixing it is one alternation:

```
^/nix/store/[a-z0-9]+-rec-.*/bin/\.rec(-tab)?-wrapped$
```

The lesson is procedural, not textual: after writing a rule, `ls` the package's
`bin/` and enumerate what is actually there.

```console
$ ls -a "$(nix build --no-link --print-out-paths nixpkgs#somepkg)/bin"
.  ..  .somepkg-wrapped  .somepkg-helper-wrapped  somepkg  somepkg-helper
```

### Trap 3 — RE2 semantics, three ways to be too loose

opensnitchd compiles rule regexes with Go's `regexp` (RE2). Three defaults bite:

- **`.` matches `/`.** RE2 has no "except separator" default. So a version
  pattern of `-.*` will happily run across directory boundaries:
  `^/nix/store/[a-z0-9]+-foo-.*/bin/foo$` also matches
  `/nix/store/<hash>-foo-1.0/share/vendor/evil/bin/foo`. This module's default
  `versionPattern` is therefore `-[^/]*`, which cannot leave the first
  component. Set `-.*` only where you need it — some packages genuinely bury the
  executable under a second versioned directory (`lib/firefox-<ver>/firefox`) —
  and know you have widened the match when you do.
- **A regex without anchors is a substring match.** `bin/nc` matches
  `.../bin/ncat`; `curl` matches `.../bin/curlftpfs`. `lint.anchors` (default
  on) asserts `^…$` on every pattern this module emits or is handed.
- **`.*` in the hash position is a wildcard over the whole path.**
  `^/nix/store/.*-curl-` will match any store path that has `-curl-` *anywhere*
  in it, including a completely unrelated package with `curl` in a subdirectory
  name. The `storeHashPattern` default is `[0-9a-z]+`, which contains neither
  `-` nor `/` and therefore cannot escape the hash field.

The lints are options, not law — `lint.anchors = false` exists — but the
defaults are the safe ones and turning them off is a decision you will see in
the diff.

### Trap 4 — the destination is a moving target; the process is not

This is the one that cost real downtime.

An antivirus updater (`freshclam`) was allowed with a deliberately tight rule:
process regex **AND** `dest.host == database.<vendor>.net` **AND**
`dest.port == 443`. It worked, then stopped, silently:

- the version check (a DNS TXT lookup) still succeeded, because the resolvers
  had their own rule;
- the actual CVD download **timed out** after roughly 132 bytes of traffic;
- the AV daemon then had no signature database at all — a security control
  disabled by a security control.

Two things had changed. The vendor put the database host behind a CDN, so the
name is now a CNAME into `*.cdn.<cdn-vendor>.net` — and the hostname OpenSnitch
attributes to a connection comes from its DNS-answer cache, so for a CNAME chain
it can be the **final target**, not the name the application asked for. And the
updater falls back to plain `:80`, which the port operand forbade.

The fix widened the destination and dropped the port entirely:

```nix
freshclam = {
  binary = "freshclam";
  hostRegex = "^(database\\.example\\.net|([a-z0-9-]+\\.)*cdn\\.example\\.net)$";
};
```

Diagnosis recipe, in order:

1. `systemctl stop opensnitchd` and retry. If it works, it is a rule, full stop.
2. `journalctl -u opensnitchd -f` while retrying — the daemon logs the process
   path and the destination it *actually* saw. That string is the ground truth
   for both operands, and it is frequently not what you assumed.
3. Only then edit the rule.

**The general rule this yields: constrain `process.path` tightly and
`dest.host` loosely.** The process identity is the security boundary and you
control it. The destination is somebody else's infrastructure decision, and it
will be re-pointed at a CDN, split across ports, or sharded across regions
without telling you. A port operand on an updater buys almost nothing and breaks
on the first HTTP fallback.

### Trap 5 — an interpreter rule is a rule for every script

`process.path` for a Python program is the *interpreter*:
`/nix/store/<hash>-python3-3.13.7/bin/python3`. So a rule that allows "the
Python tool that syncs my NAS" allows **every** Python program on the machine,
including one a user pip-installs into a venv, because they all exec the same
interpreter. Identical story for `node`, `java`, `ruby`, and for anything
launched through a shell wrapper that `exec`s an interpreter.

Mitigations, in descending order of effectiveness:

1. Constrain the destination as well — an interpreter rule scoped to one
   `dest.host` and one port is a much smaller grant than a blanket one.
2. Use `extraOperands` with `process.command` (matches the full argv, so it can
   pin the script path). Note this is a *string* match on a value the process
   itself influences, so treat it as hygiene rather than as a boundary.
3. Package the tool so it gets its own wrapper in its own store path, and match
   that instead. This is the only option that gives back a real process
   identity.

### Trap 6 — `created` must be a constant

Every rule carries a `created` timestamp. It is tempting to fill it from
`builtins.currentTime`. Do not: it makes the generated JSON change on every
evaluation, so every `nixos-rebuild` produces a new rule store path, a new
`etc`, a new system generation, and — because opensnitchd watches the rules
directory — a live rule reload for no reason. The module therefore takes a
single fixed `created` string and stamps it into everything. The default is the
epoch; pin your own if you want the field to mean something.

### Trap 7 — rules made in the GUI outlive the declarative ones

Upstream's `preStart` garbage-collects stale rules like this
(`nixos/modules/services/security/opensnitch.nix:207`):

```sh
find /var/lib/opensnitch/rules -type l -lname '/nix/store/*' ... -delete
```

`-type l` — **symlinks only**. A rule you accepted in the OpenSnitch UI ("allow
forever") is written by the daemon as a *regular file*, typically named
`000-allow-<something>.json`. It is never deleted by a rebuild, it is loaded on
every start, and it silently shadows your declarative intent for as long as the
host lives. A host that has been driven interactively for a while and is then
converted to declarative rules will behave nothing like its expression.

Before trusting a declarative ruleset:

```console
$ find /var/lib/opensnitch/rules -type f        # NOT symlinks = imperative leftovers
$ find /var/lib/opensnitch/rules -type l -ls    # the ones this module owns
```

Delete the regular files once you have translated anything worth keeping.

### Trap 8 — `DefaultAction = "deny"` fails closed and fails *quietly*

A denied connection is dropped, not rejected: no RST, no ICMP, no `ECONNREFUSED`.
The application sees a connect timeout, minutes later, and usually reports it as
a network problem. The signature vocabulary worth memorising:

| Symptom | Likely cause |
| --- | --- |
| Name resolves, TCP hangs, a few hundred bytes counted | process rule matched for DNS (resolver has its own rule) but not for the app |
| Prompt appears on every launch, "always" never sticks | the path changed since the rule was written — the GUI rule was exact |
| Works as root, fails as the service | different binary: `bin/foo` vs `bin/.foo-wrapped` (Trap 2) |
| Worked for months, broke with no local change | the destination moved (Trap 4) |

`DefaultDuration` governs how long an *interactively* answered prompt lives; on
a headless or unattended host, set `DefaultAction = "allow"` while you build the
ruleset and flip it to `deny` only once the log is quiet.

### Trap 9 — `ProcMonitorMethod` decides whether `process.path` is reliable

The default and only good choice here is `ebpf`
(`nixos/modules/services/security/opensnitch.nix:91`, and the module wires
`Ebpf.ModulesPath` to `config.boot.kernelPackages.opensnitch-ebpf` for you). The
`proc` method reads `/proc/<pid>/exe` *after* seeing the connection, which loses
short-lived processes — precisely the `curl`, `git-remote-https` and updater
one-shots that `process.path` rules exist for. A lost process gets attributed to
an unknown path and falls through to `DefaultAction`.

This module asserts `ebpf` by default (`requireEbpf`). If your kernel has no
matching `opensnitch-ebpf` build, prefer `audit` over `proc`, and expect a
noisier auditd.

### Trap 10 — this module does not touch `networking.firewall`

opensnitchd installs its own nftables (or iptables) hooks at runtime, from
`settings.Firewall`. That is independent of NixOS's `networking.firewall`
backend, so there is no conflict with `networking.nftables.enable` and this
recipe never writes `networking.firewall.extraCommands` — which the nftables
backend hard-asserts must be empty. If you set `settings.Firewall = "iptables"`,
you need an iptables build with nftables compatibility, which is what nixpkgs
ships by default.

For host-level filtering, this composes with, but does not replace,
[`firewall-by-country`](firewall-by-country.md) and
[`egress-filter`](egress-filter.md); for "which *user* may egress at all", see
[`per-uid-egress-lockdown`](per-uid-egress-lockdown.md). This recipe is the
per-*process* layer and is the only one of the four that can tell two programs
run by the same user apart.

## Usage

```nix
{
  imports = [ ./opensnitch-store-path-rules ];

  services.opensnitch.settings = {
    DefaultAction = "deny";
    DefaultDuration = "until restart";
    ProcMonitorMethod = "ebpf";
    Firewall = "nftables";
  };

  services.opensnitchStorePathRules = {
    enable = true;

    binaries = {
      # bin/curl, unwrapped
      curl = { };

      # different pname and leaf, and it is wrapped
      tailscaled = {
        pname = "tailscale";
        subpath = "bin/tailscaled";
        wrapped = true;
      };

      # executable buried under a second versioned directory: needs -.*
      thunderbird = {
        versionPattern = "-.*";
        subpath = "lib/thunderbird/thunderbird";
      };

      # interpreter, with a version pattern of its own — see Trap 5
      python3 = {
        versionPattern = "-[0-9.]*";
        pathRegex = "bin/python3(\\.[0-9]+)?";
      };
    };

    rules = {
      curl-web = {
        binary = "curl";
        ports = [ 443 80 ];
      };

      tailscaled.binary = "tailscaled";

      thunderbird-mail = {
        binary = "thunderbird";
        ports = [ 465 587 993 ];
      };

      # interpreter rule, scoped as tightly as the destination allows
      nas-sync = {
        binary = "python3";
        ports = [ 5001 ];
        hostRegex = "^nas\\.example\\.internal$";
      };

      block-telemetry = {
        action = "deny";
        hostRegex = "^([a-z0-9-]+\\.)*telemetry\\.example\\.com$";
      };
    };
  };
}
```

Rules with more than one operand are emitted as a `list` operator with the
operands in a fixed order — process, network, port, host — so the JSON is a pure
function of the spec and not of the order you wrote the options in.

### Presets

The DSL is plain data, so profiles are `//`:

```nix
let
  base = {
    tailscaled.binary = "tailscaled";
    curl-web = { binary = "curl"; ports = [ 443 80 ]; };
  };
  strict = base // {
    curl-web = { binary = "curl"; ports = [ 443 ]; };   # no plaintext
  };
in
{
  services.opensnitchStorePathRules.rules =
    if config.myHost.paranoid then strict else base;
}
```

## Options

| Option | Default | Effect |
| --- | --- | --- |
| `services.opensnitchStorePathRules.enable` | `false` | Nothing is emitted until this is on. Also sets `services.opensnitch.enable = mkDefault true`. |
| `.storeHashPattern` | `"[0-9a-z]+"` | Regex for the store hash. Never widen to `.*` (Trap 3). |
| `.versionPattern` | `"-[^/]*"` | Default fragment between pname and the first `/`. `-.*` crosses directories. |
| `.sensitive` | `false` | `sensitive` field on every generated operand. |
| `.created` | `"1970-01-01T00:00:00Z"` | Constant `created` stamp (Trap 6). |
| `.binaries.<name>.pname` | attr name | Derivation name, matched literally. |
| `.binaries.<name>.versionPattern` | `null` | Per-binary override of the module-wide pattern. |
| `.binaries.<name>.subpath` | `bin/<name>` | Path inside the output, matched literally. |
| `.binaries.<name>.wrapped` | `false` | Also match `.NAME-wrapped` (Trap 2). |
| `.binaries.<name>.pathRegex` | `null` | Raw regex for everything after the store path. |
| `.binaries.<name>.regex` | `null` | Raw regex for the whole `process.path`. Still linted. |
| `.rules.<name>.enable` | `true` | `false` removes the rule file entirely. |
| `.rules.<name>.enabled` | `true` | Ships the rule but marks it disabled to the daemon. |
| `.rules.<name>.action` | `"allow"` | `allow` / `deny` / `reject`. |
| `.rules.<name>.duration` | `"always"` | Anything else expires at runtime. |
| `.rules.<name>.precedence` | `null` | `null` omits the field; `true` evaluates the rule first. |
| `.rules.<name>.binary` | `null` | Key into `binaries`. |
| `.rules.<name>.processRegex` | `null` | Raw `process.path` regex instead of `binary`. |
| `.rules.<name>.processPath` | `null` | Exact `process.path` (Trap 1's strong-but-expiring form). |
| `.rules.<name>.network` | `null` | `dest.network` CIDR. |
| `.rules.<name>.ports` | `[ ]` | One port ⇒ `simple`; several ⇒ one anchored alternation. |
| `.rules.<name>.host` / `.hostRegex` | `null` | `dest.host`, exact or regex (Trap 4). |
| `.rules.<name>.extraOperands` | `[ ]` | Raw operands (`user.id`, `process.command`, `iface.out`, …). |
| `.extraRules` | `{ }` | Raw rules merged verbatim into `services.opensnitch.rules`. |
| `.requireEbpf` | `true` | Assert `ProcMonitorMethod == "ebpf"` (Trap 9). |
| `.lint.anchors` | `true` | Assert `^…$` on every process regex. |
| `.lint.absolutePaths` | `true` | Assert every process regex is rooted at `/`. |
| `.lint.emptyRules` | `true` | Assert no rule compiles to zero operands. |

`lint.emptyRules` is worth a sentence of its own: a rule with no operands is not
a no-op, it is a **match-everything** rule. `myrule = { };` with the default
`action = "allow"` disables the firewall, and does it in a way that reviews
cleanly. The assertion turns that into an evaluation failure.

## Tests

`test.nix` is a NixOS VM test of the module itself. Run it standalone:

```sh
nix-build test.nix --arg pkgs 'import <nixpkgs> { system = "x86_64-linux"; }'
```

or from a flake: `pkgs.callPackage ./modules/opensnitch-store-path-rules/test.nix { }`.

Three nodes. `origin` serves HTTP and echoes back the client's source address.
`shaped` uses this module. `pinned` is the naive alternative — one hand-written
rule holding a literal store path — kept in the test as a **live control**.
Addresses come from [`lib/nixos-test-topology`](../../lib/nixos-test-topology).

The subject is a set of probe binaries built at store paths whose shape the test
controls: `netprobe-1.0`, the *same* pname and version rebuilt to a different
hash (a dependency bump), `netprobe-2.0`, and
`netprobe-2.1-unstable-2026-07-28`. They are real working `curl`s, so a rule
decision is observable as an HTTP request that either completes or does not.

What it proves:

1. **Eval time.** Every lint is live: an unanchored `process.path` regex, a rule
   that compiles to zero operands, a reference to an undefined binary and
   `ProcMonitorMethod = "proc"` each produce a failing assertion; a well-formed
   config produces none. Checked by reading `config.assertions` from a plain
   non-VM evaluation, because an assertion failure aborts before there is a VM.
2. **The generated rule matches the CURRENT store path** — of all four builds,
   against the paths `realpath` resolves inside the guest, read from the rule
   file opensnitchd actually loaded from `/var/lib/opensnitch/rules`.
3. **It pins nothing.** No build's store hash appears anywhere in the rule file.
4. **It is not merely broad.** Five near-miss paths must *not* match: a foreign
   pname, a pname the target is a prefix of (`netprobelike-1.0`), a longer leaf
   (`bin/netprobe-helper`), the wrong subdirectory (`libexec/`), and a
   `.netprobe-wrapped` payload under a binary not declared `wrapped`.
5. **`wrapped = true` matches both** the wrapper and its `.NAME-wrapped` payload.
6. **Behaviourally, end to end**, with opensnitchd running and `DefaultAction =
   "deny"`: all four builds plus both wrapped forms fetch the page; all five
   near-misses time out. Same node, same URL, byte-identical binaries, seconds
   apart — the only difference is the store path, which is what rules out "the
   network was down" as the reason a denied probe failed.
7. **The point.** On `pinned`, the literal rule allows the exact path it names
   and blocks all three rebuilds. On `shaped`, the same three rebuilds are
   allowed. If this module ever regressed into pinning a path, the two nodes
   would agree and the test would fail.

Not covered: the GUI/database side (Trap 7) and precedence ordering between
declarative and runtime rules.

### Verified by breaking it

A test nobody has watched fail is a claim. Each of these was applied to a copy
of the recipe and the test was re-run:

| break | result |
|-------|--------|
| Delete the `emptyRules` assertion | eval fails: `a rule that compiles to zero operands is rejected` |
| Emit `bin/netprobe.*$` instead of `bin/netprobe$` — still anchored, still passes every lint | static lane fails: `decoy leaf-suffix matched: …/bin/netprobe-helper` |
| Same break, static lane blinded | behavioural lane fails on its own: `decoy leaf-suffix was allowed; the rule is too broad` — and the decoy genuinely reached `origin` (rc=0, source address echoed), so the deny in the passing run is a real deny |
| Regress the rule to a literal store path in `regexp` form (passes every lint and every static type check), static lane blinded | behavioural lane fails: `v1-rebuilt was blocked but should have been allowed`, with `v1` succeeding moments earlier |

The first break run also exposed a race in the test itself: opensnitchd reports
`active` about half a second before it logs `[eBPF] module loaded`, so the
monitor-method check is a `wait_until_succeeds`, not a `succeed`.

Note that [`nixos-test-topology`](../../lib/nixos-test-topology)'s Trap 4 —
client and destination must be on different subnets — does **not** apply here.
OpenSnitch filters the client's own outbound connections on the client itself;
there is no forward hook to ARP around. The equivalent "did the filter actually
run" instrument is the paired allow/deny control in (6).

## Caveats

- **Only `process.path` regexes are linted.** `hostRegex` and anything in
  `extraOperands` are passed through untouched — deliberately, because a
  destination pattern is usually *supposed* to be broad (Trap 4).
- **`operator.list` carries no `data` field here.** The daemon's own UI writes
  a JSON-encoded copy of the operand list into `data` when it saves a rule;
  opensnitchd accepts both forms on load, but a rule round-tripped through the
  GUI will not be byte-identical to the generated one. Use `extraRules` if you
  need to reproduce a hand-written rule exactly.
- **Container and VM processes are invisible-ish.** A process in a container
  reports the path inside *its* mount namespace, which is not a host store path;
  a VM's guest traffic appears as the hypervisor binary. Match the hypervisor or
  the container runtime and constrain the destination — you cannot distinguish
  guests this way.
- **Multi-process applications need multiple rules.** Browsers, Electron apps
  and anything with helper processes may connect from a helper whose path
  differs from the launcher. Read the daemon log rather than guessing.
- **Rule files are named after the attribute key** and loaded from
  `settings.Rules.Path`. Ordering between rules of equal precedence is not
  something to depend on; use `precedence = true` for a deny that must win.
- **Version bounds.** Written against nixpkgs `26.11` (`opensnitch` 1.8.0). The
  rule schema used here — `type = "list"` operators with nested operands,
  `regexp` operands on `process.path` / `dest.host` / `dest.port` — has been
  stable since 1.4. `Ebpf.ModulesPath` and the `Rules.Path`-must-be-under-
  `/var/lib` assertion are nixpkgs-module behaviour, not upstream's.
- **This is not a sandbox.** A process that can `execve` a different binary, or
  that is already allowed to reach a host that proxies onward, is not contained
  by a path rule. It is an *observability and mistake* control: it tells you
  what talks to what, and stops the things you did not intend. Pair it with a
  real isolation mechanism where that matters.
