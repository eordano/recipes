# nix-remote-builders

A **table** of remote Nix builders, a **routing** rule that decides which of
them each host may use, and the generated `ssh_config` that makes the whole
thing work — plus `nix-builder-bench`, the harness that turns `speedFactor`
from a guess into a measurement.

Two halves, one recipe, because they only make sense together: the module is
where a number like `speedFactor = 5` is written down, and the benchmark is
where that number comes from.

```nix
nix.remoteBuilders = {
  builders.eu-big = {
    hostName = "eu-big-builder";        # ssh ALIAS, not DNS
    address  = "10.10.0.2";
    port     = 2222;
    user     = "nixbuilder";
    systems  = [ "x86_64-linux" ];
    maxJobs  = 16;
    speedFactor = 5;
    features = [ "big-parallel" "kvm" ];
    identityFile = "/run/secrets/builder-key";
  };
  routes.laptop-eu = [ "eu-big" ];
  excludedHosts    = [ "eu-big-builder-host" ];
};
```

## The problem

Upstream gives you the *file format* and nothing else.
`nixos/modules/config/nix-remote-build.nix` declares `nix.buildMachines` and
`nix.distributedBuilds`, and its entire `config` section (lines 229–254) writes
one thing:

```nix
environment.etc."nix/machines" = mkIf (cfg.buildMachines != [ ]) {
  text = buildMachinesText;
};
```

That leaves three things unowned, and each of them is a separate outage:

1. **The SSH client configuration.** Nix's own docs for the `builders` setting
   say the hostname "may be an alias defined in `~/.ssh/config`" — but nothing
   in nixpkgs writes that alias for you, and the alias is where the port, the
   login account, the key and (crucially) the connection-multiplexing policy
   live. `ControlMaster` appears **zero times** across all 2436 `.nix` files
   under `nixos/modules/` in nixpkgs `nixos-unstable` (`.version` 26.11). So
   does `ControlPath`. So does `ControlPersist`. Upstream has no opinion, and
   the default opinion is the one that breaks builds.

2. **Who uses whom.** `nix.buildMachines` is per-host, so a fleet either
   repeats the same list in 20 configurations or writes a shared list that is
   wrong for most of them.

3. **`speedFactor`.** It is a bare integer with a default of `1` and no
   guidance beyond "higher is faster". Everybody types core counts into it.

## Traps

### Trap 1 — SSH connection multiplexing breaks `protocol = "ssh-ng"`

This is the one that costs a day.

`ssh-ng` runs Nix's *daemon* worker protocol over the SSH channel. A remote
build fans out many concurrent connections; with `ControlMaster auto` in
effect every one of them is a multiplexed session on a single control socket.
Sessions then interleave on the shared transport in ways the protocol handshake
does not survive, and Nix fails while reading the magic word it expects back:

```
error: protocol mismatch
error: protocol mismatch, got '…'
error: nix-daemon protocol mismatch from …
error: serialised integer … is too large for type '…'
```

(All four strings are in `libnixstore.so`; the last is the one you get when the
stream is merely *desynchronised* rather than obviously wrong, and it is the
most confusing of the set because it looks like a corrupt store rather than a
transport problem.)

The bit that makes this hard to find: **Nix never asks for multiplexing.**
Dumping the strings out of `libnixstore.so` (Nix 2.31.5) shows the complete set
of ssh options Nix passes on the command line —

```
-oUserKnownHostsFile=
-oPermitLocalCommand=yes
-oLocalCommand=echo started
```

— and no `ControlMaster`, `ControlPath` or `ControlPersist` at all. When Nix
*does* want a master it opens its own, on a socket it names `ssh.sock` inside a
private temp directory. So multiplexing never appears in a Nix command line, is
never mentioned in a Nix error, and comes entirely from `ssh_config`, which is
the last file anyone looks at while debugging a build failure.

Hence: every generated builder block ends with

```
  ControlMaster no
  ControlPath none
  ControlPersist no
```

`ControlPath none` is not redundant with `ControlMaster no`. `ControlMaster no`
means "do not *become* a master"; a plain `ControlPath` pointing at an existing
socket still makes this connection *use* one. You have to say both.

### Trap 2 — the fix only works because of `mkBefore`

`ssh_config` is **first-match-wins per keyword**: for each option, the first
value obtained is used, and later ones are discarded. Almost every non-trivial
`ssh_config` ends with

```
Host *
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
```

If the builder blocks are emitted *after* that, `Host *` has already matched
and already supplied `ControlMaster`, and the builder block's `ControlMaster
no` is dead text. Nothing warns you. `ssh -G <builder>` will happily print
`controlmaster auto` while your configuration says `no` three lines below.

So the module emits its blocks with `lib.mkBefore`:

```nix
programs.ssh.extraConfig = lib.mkBefore (lib.concatMapStrings sshBlock selected);
```

That is not house style, it is the mechanism. And it interacts with upstream:
`nixos/modules/programs/ssh.nix:116` documents `extraConfig` as "Extra
configuration text **prepended** to `ssh_config`. Other generated options will
be added after a `Host *` pattern", and the implementation (same file, lines
342–350) does exactly that — `extraConfig` first, then a literal `Host *`
section with the module's own settings. So `extraConfig` is already ahead of
*nixpkgs'* `Host *`; `mkBefore` is what keeps you ahead of every *other module
in your own tree* that also writes `extraConfig`.

Check it on a live host with the one command that reads the merged result
rather than the file:

```console
$ ssh -G eu-big-builder | grep -E '^control(master|path|persist)'
controlmaster no
controlpath none
controlpersist no
```

On nix-darwin the same text lands in
`/etc/ssh/ssh_config.d/100-nix-darwin.conf` (`modules/programs/ssh.nix:177`),
which the system `ssh_config` includes near the top — but note that
`~/.ssh/config` is read **before** `/etc/ssh/ssh_config`. A `Host *` block with
`ControlMaster auto` in the *root user's* personal config therefore beats
everything this module writes, on any platform, because the Nix daemon connects
as root. If builds still break after deploying this, `grep -r ControlMaster
/root/.ssh/config` before anything else.

### Trap 3 — a persistent master injects a STALE environment into later sessions

Even where multiplexing does not break the protocol, `ControlPersist` is wrong
here for a second, independent reason.

Channel-level state belongs to the **master**, not to the session riding it:
the forwarded agent socket, the X11 cookie, and every port forward were
established by whichever login opened the master. With `ControlPersist 10m` the
master outlives that login. Ten minutes later, a new `ssh` reuses it, and the
remote side gets `SSH_AUTH_SOCK` pointing at a forwarding endpoint whose owning
login is gone — so an onward `git fetch` on the builder fails
`Permission denied (publickey)` while `ssh-add -l` on your workstation lists
the key perfectly. `SSH_CONNECTION` likewise describes the old connection.

For a *build* machine this is worse than for a shell, because it is invisible:
nothing interactive fails, a fetch inside a build just gets denied and the
build looks like a source problem.

The sibling recipe [`tmux-ssh-agent-stable-sock`](tmux-ssh-agent-stable-sock.md)
solves the same family of bug from the other end, for interactive sessions.

### Trap 4 — `builders-use-substitutes` defaults to **false**

Nix's own default (confirmed against Nix 2.34.8: `nix config show --json`
reports `"defaultValue": false`) means the local machine uploads the closure of
every build input to the builder. Your laptop fetches a 400 MB toolchain from
`cache.nixos.org` and then pushes it, over your uplink, to a machine sitting in
a datacentre that could have fetched it at 10 Gbit/s.

```nix
nix.settings.builders-use-substitutes = true;
```

This module sets it by default. It is the single largest win in most remote
build setups and it is a one-line setting nobody turns on, because the option
lives in Nix rather than NixOS and never shows up in a NixOS options search.

### Trap 5 — route by LOCALITY, not by "biggest box"

The obvious routing rule is "everything goes to the fastest machine". It is
wrong, and the reason is Trap 4 in reverse: what a remote build actually costs
is *round trips of store paths across the link between you and the builder*.

Order the route by network distance first and raw speed second. A machine on
the same LAN with half the cores beats a machine three times faster on the far
side of a 17 Mbit uplink for everything except the rare enormous compile — and
for the *typical* build, which is dominated by copying inputs in and outputs
back, it is not close.

`routes` is therefore an **ordered list per host**, and the order is preserved
into `/etc/nix/machines`. Combined with `speedFactor` (which Nix uses to pick
among eligible machines, taking load into account) you get "prefer the near
one, spill to the far one".

Also in `excludedHosts`: the builders themselves. A builder that routes to
itself will happily schedule its own jobs through an SSH round trip and
compete with itself for the same job slots.

### Trap 6 — `lib.unique` on key names, because builders share keypairs

It is normal for several builder entries to share one keypair — same key, same
`authorized_keys` line, different ports or different accounts. The naive
`map (b: b.keyName) selected` then contains duplicates.

`lib.genAttrs` happens to survive that (equal values collapse), which is
exactly why the bug ships: it is invisible until the day someone feeds the same
list to something list-shaped — a `mkMerge` of per-key attrsets, a tmpfiles
rule per key, an `age.rekey` list, an assertion enumerating keys — and gets
`The option 'age.secrets.<name>' has conflicting definitions` or two identical
tmpfiles lines fighting over one path. The de-duplication therefore happens
once, at the boundary, in the read-only `keyNames` option, and every consumer
reads that:

```nix
keyNames = lib.unique (map (b: b.keyName) (builtins.filter (b: b.keyName != null) selected));
```

Note `selected`, not `builders`: a host that routes to no builder must declare
**no** key at all, or every appliance in the fleet grows a secret it cannot use
and a rekey step it does not need.

### Trap 7 — `IdentitiesOnly yes`, or an agent exhausts `MaxAuthTries`

`IdentityFile` *adds* a key to the list ssh will offer; it does not restrict
it. With a loaded agent, ssh offers every agent key first, in agent order. The
remote `sshd` counts each offer against `MaxAuthTries` (default **6**) and
closes the connection when it runs out — before the key you actually named is
ever tried.

The symptom is the least helpful message in OpenSSH:

```
Received disconnect from …: Too many authentication failures
```

It appears the day someone adds a seventh key to their YubiKey-backed agent,
on a fleet that has been fine for a year, and it looks like a server-side
change. `IdentitiesOnly yes` (emitted whenever an `IdentityFile` is emitted)
restricts the offer to the named key.

### Trap 8 — the key must not live in the Nix store

nixpkgs says so in the option description itself
(`nixos/modules/config/nix-remote-build.nix`, `sshKey`, lines 137–150):

> Note that for security reasons, this path must point to a file in the local
> filesystem, *not* to the nix store.

Store paths are world-readable. This module asserts it rather than trusting the
comment, because `sshKey = ./builder-key` is a very natural thing to write and
it silently publishes the key to every user on the machine.

### Trap 9 — you cannot `mkIf` away a definition for an option that may not exist

The agenix integration lives in a **separate file** (`./agenix.nix`) that you
import only if you use agenix. That is not tidiness. The single-file version —

```nix
config = mkIf cfg.agenix.enable { age.secrets = …; };
```

— fails on every host that has no agenix module *even with the feature turned
off*:

```
error: The option `age' does not exist. Definition values:
       - In `…/nix-remote-builders': { _type = "if"; condition = true;
           content = { _type = "if"; …
```

The module system pushes properties **down into each attribute** before it
matches definitions against declarations, so `age` is registered as a defined
path first and the `mkIf` is evaluated second. `lib.optionalAttrs` would hide
the name properly, but its condition would have to read `config`, which is
infinite recursion: the *shape* of a module's `config` may not depend on the
merged `config`.

So: two files, and a read-only `keyNames` option for everyone using something
other than agenix.

### Trap 10 — one program, one `bash -s`, one `nix shell`

Now the benchmark half. `nix-builder-bench` generates the *entire* remote
program in memory and pipes it into a single `bash -s` per host, and the first
thing that program does is

```bash
exec nix shell $NIX_PKGS --command bash -s <<'__NIXBENCH_INNER__'
```

Everything after that runs inside one shell. Two consequences, both of which
are the difference between a benchmark and a rumour:

- **Identical toolchain, no PATH drift.** `hyperfine`, `fio`, `jq` and
  `coreutils` are the same store paths for every benchmark on every host. Run
  the benchmarks as separate `ssh host 'nix shell … -c hyperfine …'` commands
  instead and each one re-resolves the flake — on a host whose registry drifted
  you compare a different `hyperfine` against a different `fio`.
- **The realisation cost is paid once, outside the measured region.** The
  first run downloads `fio`; if that lands inside a timed command you have
  measured the mirror.

The `exec` matters too: no wrapper shell stays alive holding a pipe, so the
remote process tree is one shell and the connection closes cleanly when it
exits.

### Trap 11 — warmup runs discarded, and `$RANDOM$$` for a genuine cache miss

`hyperfine --warmup 1 --runs 3` throws the first iteration away. Without it the
cold page cache and the cold Nix database land in the median, and a machine
with more RAM looks faster than it is at steady state.

The opposite mistake is in the Nix micro-benchmark. This:

```bash
nix build --impure --expr 'derivation { name = "bench"; … }'
```

is a **store hit** after the first iteration. Every host reports a couple of
milliseconds and the benchmark ranks them by the speed of a hash lookup. The
fix is one variable in the derivation name:

```bash
R=$RANDOM$$; nix build … "derivation { name = \"bench-$R\"; … }"
```

`$RANDOM` alone is not enough under parallelism (bash seeds it per process and
two hosts can collide); `$$` disambiguates. Every iteration is now a derivation
Nix has never seen, so the measurement includes hashing, writing the `.drv`,
forking the builder, and registering the output — a real build round trip. On
the machine this recipe was verified on that is the difference between "a few
ms" and a **median of 557 ms**.

Two further things the micro-benchmark needs, both found by running it:

- **`--builders ''`.** A host that already has remote builders configured
  forwards the derivation straight back out. Observed verbatim:
  `building '/nix/store/….drv' on 'ssh-ng://builder@…'` — the benchmark was
  measuring a third machine over the network. (The override only applies if you
  are a trusted user on that host; otherwise Nix ignores the flag.)
- **`builtins.storePath`, not a bare string.** A literal `"/nix/store/…/bash"`
  carries no string context, so it is not an input of the derivation and the
  sandbox does not bind-mount it:

  ```
  error: executing '/nix/store/…-bash-5.3/bin/bash': No such file or directory
  ```

  Wrapping the store root in `builtins.storePath` gives the string context back
  and the path becomes an input.

### Trap 12 — the harness turns multiplexing back ON, deliberately

The harness opens exactly one master per host and reuses it for the whole run,
because setting up a fresh TCP+SSH handshake per benchmark would add tens of
milliseconds of jitter to measurements whose interesting differences are tens
of milliseconds.

It can do that even though `ssh_config` says `ControlMaster no`, because
**command-line `-o` beats the config file** under first-match-wins. The
builder blocks keep protecting Nix; the harness opts itself out for one
invocation:

```bash
ssh -o ControlMaster=auto \
    -o "ControlPath=$SSH_CTRL_DIR/%r@%h:%p" \
    -o ControlPersist=60s \
    -o BatchMode=yes -o ServerAliveInterval=30 …
```

And it *must* spell `ControlPath` explicitly, because of the teardown:

```bash
cleanup() {
  for label in "${HOST_LABELS[@]}"; do
    ssh -o "ControlPath=$SSH_CTRL_DIR/%r@%h:%p" -O exit "$host" 2>/dev/null || true
  done
  rm -rf "$SSH_CTRL_DIR"
}
trap cleanup EXIT INT TERM
```

`ssh -O exit` can only close a socket whose path it is told; there is no "the"
control path to inherit. Without both the explicit path and the `EXIT INT TERM`
trap, a Ctrl-C during a benchmark leaves a 60-second master behind — and that
master is exactly the Trap 3 stale-environment machine, now sitting in front of
your builders.

### Trap 13 — `speedFactor` is a small positive INTEGER

Nix's `builders` documentation: "The 'speed factor', indicating the relative
speed of the machine as a **positive integer**." There are no fractions. A
measured 1.7× ratio has to be rounded onto whatever scale you keep consistent
across the fleet, and that scale has to leave room — if your fastest machine is
`2`, you cannot express "slightly slower than that".

Pick a scale (this recipe's examples use 1–10), map the benchmark's `VS BEST`
column onto it, and write the measurement date next to it. A `speedFactor`
without a date is a guess that has been laundered into a fact.

Note also that Nix takes *current load* into account on top of `speedFactor`,
so the number does not need to be precise — it needs to be *ordered* correctly.

## The benchmark half, end to end

```console
$ nix-builder-bench 'near | ssh near-builder' 'far | ssh far-builder' 'here | local'
================================================================
Nix Builder Benchmark — 2026-07-28T15:09:05
================================================================
  hosts:     here near far
  benches:   sysinfo cpu_single cpu_multi disk_seq nix_eval nix_build

━━━ System Info ━━━
  HOST  OS/ARCH       CPUS  MEMORY  GPU   NIX
  here  Linux/x86_64  24    125Gi   none  2.34.8

━━━ Timing ━━━  median / p95 — lower is better
  BENCHMARK  HOST   MEDIAN      P95      MIN      MAX   STDDEV  RUNS  VS BEST
  nix_eval   here   19.5ms   17.4ms   17.4ms   21.6ms   ±3.0ms     2  1x
  nix_build  here  557.1ms  511.3ms  511.3ms  603.0ms  ±64.9ms     2  1x

━━━ Disk throughput ━━━  larger is better
  BENCHMARK  HOST     TIME       WRITE        READ  VS BEST (write)
  disk_seq   here  780.0ms  317.9 MB/s  338.5 MB/s  1x
```

Reading it:

- `cpu_multi` is the closest single proxy for `speedFactor` on compile-bound
  work; `nix_build` catches store/database slowness that core counts hide;
  `disk_seq` catches the machine that is fast until it writes.
- Hosts run **in parallel**, one background job each, so the wall clock is one
  host's runtime, not the sum — but that also means the machines are loading
  the same network at the same time. Benchmark disk and CPU in parallel;
  re-measure anything network-shaped serially.
- Every host writes `results.tsv` plus a per-host `.log`, so a `status=fail`
  row can be diagnosed after the fact.

Enabling it declaratively pre-loads the host table with the builders **this
host actually routes to**, through the same ssh aliases the builds use:

```nix
nix.remoteBuilders.benchmark.enable = true;
```

## Usage

### Minimal

```nix
{
  imports = [ ./nix-remote-builders ];

  nix.remoteBuilders = {
    builders.near = {
      hostName = "near-builder";
      address  = "10.10.0.2";
      user     = "nixbuilder";
      systems  = [ "x86_64-linux" ];
      maxJobs  = 8;
      speedFactor = 3;
      features = [ "big-parallel" "kvm" ];
      identityFile = "/run/secrets/builder-key";
    };
    defaultRoute = [ "near" ];
    excludedHosts = [ "near-builder-host" ];
  };
}
```

### Fleet-shaped, with agenix

```nix
{
  imports = [
    ./nix-remote-builders
    ./nix-remote-builders/agenix.nix
  ];

  nix.remoteBuilders = {
    builders = {
      near = { hostName = "near-builder"; address = "10.10.0.2"; keyName = "builder-key"; systems = [ "x86_64-linux" ]; maxJobs = 8;  speedFactor = 3; };
      far  = { hostName = "far-builder";  address = "10.20.0.2"; keyName = "builder-key"; systems = [ "x86_64-linux" ]; maxJobs = 16; speedFactor = 5; };
    };

    # Ordered by network distance, not by size.
    routes = {
      office-desktop = [ "near" ];
      home-laptop    = [ "far" "near" ];
    };
    defaultRoute  = [ "near" ];
    excludedHosts = [ "near-builder-host" "far-builder-host" "tiny-appliance" ];

    agenix = {
      enable = true;
      secretsDir = ./secrets;      # <secretsDir>/<keyName>.age
    };
  };
}
```

Both builders share one keypair; exactly one secret is declared, and only on
hosts that route somewhere.

### Some other secret manager

Do not import `agenix.nix`. Read the de-duplicated list yourself:

```nix
sops.secrets = lib.genAttrs config.nix.remoteBuilders.keyNames (name: {
  sopsFile = ./secrets/${name}.yaml;
  mode = "0400";
});
nix.remoteBuilders.builders.near.identityFile = config.sops.secrets.builder-key.path;
```

## Options

| Option | Default | Effect |
| --- | --- | --- |
| `nix.remoteBuilders.enable` | `true` | Master switch. Emits nothing on a host that routes nowhere, so it is safe to import fleet-wide. |
| `.hostName` | `networking.hostName` | Key used for `routes` / `excludedHosts` lookup. |
| `.builders` | `{ }` | The table. Attribute name is the routing key. |
| `.builders.<n>.hostName` | attr name | Name in `/etc/nix/machines` **and** the `Host` pattern. An alias, not DNS. |
| `.builders.<n>.address` | `null` | `HostName` line. `null` ⇒ the alias must resolve by itself. |
| `.builders.<n>.port` | `22` | `Port` line. |
| `.builders.<n>.user` | `"builder"` | `User` line and `sshUser`. Must be in the remote's `trusted-users`. |
| `.builders.<n>.identityFile` | `null` | Key path. Asserted **not** to be a store path. |
| `.builders.<n>.keyName` | `null` | Secret name; de-duplicated into `keyNames`. |
| `.builders.<n>.systems` | `[ ]` | Asserted non-empty for routed builders. |
| `.builders.<n>.maxJobs` | `1` | Scheduling hint; there is no work-stealing between machines. |
| `.builders.<n>.speedFactor` | `1` | Positive integer. See Trap 13. |
| `.builders.<n>.features` | `[ ]` | `supportedFeatures`. Empty removes the machine from every `kvm` / `big-parallel` build. |
| `.builders.<n>.mandatoryFeatures` | `[ ]` | Inverted matching — reserves the machine. |
| `.builders.<n>.publicHostKey` | `null` | base64 host key; pins first contact. |
| `.builders.<n>.protocol` | `"ssh-ng"` | See Trap 1 before changing multiplexing policy. |
| `.builders.<n>.sshExtraLines` | `[ ]` | Extra lines inside this builder's block, e.g. `ProxyJump`. |
| `.routes` | `{ }` | host → **ordered** builder names. Order is network distance. |
| `.defaultRoute` | `[ ]` | Route for hosts with no entry. |
| `.excludedHosts` | `[ ]` | Never offload: the builders themselves, tiny appliances. |
| `.strictRoutes` | `false` | Assert instead of silently dropping route names absent from the table. |
| `.distributedBuilds` | `true` | `nix.distributedBuilds`. |
| `.useSubstitutes` | `true` | `builders-use-substitutes`. Nix's default is `false`. See Trap 4. |
| `.ssh.manageClientConfig` | `true` | Emit the `Host` blocks at all. |
| `.ssh.disableMultiplexing` | `true` | The three `Control*` lines. **Keep this on.** |
| `.ssh.identitiesOnly` | `true` | `IdentitiesOnly yes`. See Trap 7. |
| `.ssh.strictHostKeyChecking` | `"accept-new"` | `null` emits no line. |
| `.ssh.indent` | `"  "` | Indentation inside a `Host` block. |
| `.agenix.enable` | `false` | Resolve `identityFile` from `age.secrets.<keyName>.path`. Needs `./agenix.nix`. |
| `.agenix.secretsDir` | `null` | `<secretsDir>/<keyName><fileSuffix>`. |
| `.agenix.fileSuffix` | `".age"` | |
| `.agenix.generatorScript` | `"ssh"` | agenix-rekey `generator.script`. `null` for plain agenix. |
| `.agenix.owner` / `.mode` | `"root"` / `"0400"` | ssh refuses a group- or world-readable key. |
| `.agenix.extraSecretConfig` | `{ }` | Merged into every declared secret. |
| `.benchmark.enable` | `false` | `nix-builder-bench` in `systemPackages`, pre-loaded with this host's route. |
| `.benchmark.targets` | `null` | `label -> command`; `null` derives from the route. |
| `.benchmark.benchmarks` | `[ sysinfo cpu_single cpu_multi disk_seq nix_eval nix_build ]` | `disk_rand` and `mem_bw` also exist. |
| `.benchmark.runs` / `.warmupRuns` | `3` / `1` | Warmup runs are discarded. See Trap 11. |
| `.benchmark.diskSizeMB` | `256` | fio working set. |
| `.benchmark.toolPackages` | `nixpkgs#{hyperfine,fio,coreutils,jq,bash}` | Realised once per host, inside the single `nix shell`. |
| `.selectedNames` | read-only | Builder names this host resolved to, in order. |
| `.keyNames` | read-only | De-duplicated key names for the routed builders only. |

## Caveats

- **The benchmark needs flakes and a `nixpkgs` registry entry on the remote.**
  `nix shell nixpkgs#hyperfine` fails on a host whose registry points at a
  channel path with `access to absolute path '…/flake.nix' is forbidden in pure
  evaluation mode`. Pin `toolPackages` to a store path or a locked flake ref
  for a measurement campaign — it also makes the toolchain identical across
  hosts by construction rather than by luck.
- **`disableMultiplexing` protects the builder aliases only.** Everything else
  in your `ssh_config` keeps whatever multiplexing policy it had; this module
  does not and should not touch it.
- **A route naming an unknown builder is silently dropped** so that a table
  assembled from a partially-known address book degrades instead of breaking
  every host at once. Set `strictRoutes = true` if you would rather it failed.
- **`accept-new` trusts first contact.** It refuses a *changed* key, which is
  the attack most people care about, but it will accept an impostor on the very
  first connection. Set `publicHostKey` per builder where that matters.
- **This module does not make the remote a builder.** The remote still needs
  `nix.settings.trusted-users` to include the login account, and the account's
  `authorized_keys` to carry the public half. Pair with
  [`private-nix-cache-substituter`](private-nix-cache-substituter.md) or
  [`harmonia-cache-with-upstream-fallback`](harmonia-cache-with-upstream-fallback.md)
  if you also want the builder's output shared, and
  [`signed-binary-cache`](signed-binary-cache.md) if it should be trusted by
  more than its own owner.
- **For scheduled/queued builds you want a real CI system,** not
  `nix.buildMachines` — see [`hydra-ci-server`](hydra-ci-server.md). This
  recipe is for interactive and deploy-time builds.
- **Key material handling** is out of scope beyond the `keyNames` boundary;
  [`agenix-rekey-yubikey-per-host`](../lib/agenix-rekey-yubikey-per-host.md)
  covers the generation and rekeying side.
