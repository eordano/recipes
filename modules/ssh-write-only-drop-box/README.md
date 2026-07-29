# ssh-write-only-drop-box

A **write-only artifact drop-box over SSH**. CI boxes `rsync` a directory in and
can never read, list, delete or overwrite anything. A systemd path unit notices
each drop, waits for it to be complete, and either **promotes** it into
`published/` or **quarantines** it with a machine-readable reason.

```
CI runner ──rsync──▶ sshd ──ForceCommand──▶ rrsync -wo ──▶ <dataDir>/incoming/<id>/
                                                                   │
                                              <name>-watch.path ◀───┘ (inotify)
                                                     │
                                       <name>-dispatch.service   one worker per drop
                                                     │
                                            <name>@<id>.service
                                          ┌──────────┴──────────┐
                                  published/<id>          quarantine/<id>
                                   + onPromoted            + <id>.reason
                                                           + onQuarantined
```

The whole security property is one sentence: **write-only is enforced at the SSH
transport layer, not by the application.** Everything below is about the ways
that sentence is half-implemented.

Ships with a three-node NixOS VM test (`test.nix`) whose third node is a
deliberate **half implementation**, so every "the drop-box refused" assertion is
paired with the same request succeeding against the broken build. See
[Testing](#testing).

## The problem

You want a box that collects build artifacts. The obvious shape — an account
with an `authorized_keys` file and a shared directory — is wrong in a specific
way: an account that can write can also read, so every CI runner in the fleet
can enumerate and exfiltrate every other project's artifacts, and a compromised
runner can quietly rewrite history in `published/`.

The fix is to make the *transport* refuse, and then to make the intake side
survive the fact that `rsync` will hand you half-finished directory trees.

### What upstream nixpkgs does not do

nixpkgs has all the parts and none of the assembly.

- `nixos/modules/services/networking/ssh/sshd.nix:98` defines
  `users.users.<name>.openssh.authorizedKeys.keys` as a
  `listOf singleLineStr` that is written **verbatim** into
  `/etc/ssh/authorized_keys.d/<user>` (`mkAuthKeyFile`, same file, lines
  143–160). There is no concept of a restricted role, a forced command, or a
  chroot. Whatever you put in the string is what you get.
- `nixos/modules/services/networking/ssh/sshd.nix:444` defines
  `services.openssh.authorizedKeysInHomedir` with **`default = true`**, and
  lines 885–887 turn that into
  `AuthorizedKeysFile %h/.ssh/authorized_keys /etc/ssh/authorized_keys.d/%u`.
  So on a stock NixOS host, *every* user's home directory is a key store. That
  matters here more than anywhere, because this user's home *is* the drop-box.
- `pkgs/by-name/rr/rrsync/package.nix` packages the `rrsync` wrapper from the
  rsync source tree and stops there. No module consumes it.

There is no upstream "receive artifacts over ssh" module, so the assembly — and
every trap in it — is yours to get right.

## Traps

### Trap 1 — `PubkeyAuthOptions none` does not disable per-key options

The near-miss version of this recipe pairs the forced command with:

```
Match User dropbox
  PubkeyAuthOptions none
```

on the belief that it strips `command=` / `restrict` handling and makes the
server-side policy authoritative. It does nothing of the sort.
`sshd_config(5)` (OpenSSH 10.4p1):

> **PubkeyAuthOptions** — Sets one or more public key authentication options.
> The supported keywords are: `none` (**the default**; indicating no additional
> options are enabled), `touch-required` and `verify-required`.

It is FIDO authenticator policy, and `none` is already the default. That `Match`
block is a **no-op**. Anyone who reads it and concludes "good, the server owns
the command" is wrong, and the entire write-only property is resting on a
string prefix inside `authorized_keys` — a file whose contents are exactly what
you were trying to stop trusting.

The keyword that actually does the job is `ForceCommand`, which is legal inside
a `Match` block (`sshd_config(5)`, the "Only a subset of keywords may be used"
list) and which:

> Forces the execution of the command specified by ForceCommand, **ignoring any
> command supplied by the client** and `~/.ssh/rc` if present.

It also beats a `command=` carried by the key, so a key that acquires its own
options — appended by hand, restored from a backup, or planted — still cannot
get a shell. This module emits:

```
Match User dropbox
  AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u
  ForceCommand /nix/store/…-rrsync-3.4.4/bin/rrsync -wo -no-del /srv/artifacts/incoming
  PermitTTY no
  PermitUserRC no
  DisableForwarding yes
```

Verify it on any host, without connecting:

```console
$ sshd -T -f /etc/ssh/sshd_config -C user=dropbox,host=x,addr=1.2.3.4 | grep -i forcecommand
forcecommand /nix/store/…/rrsync -wo -no-del /srv/artifacts/incoming
$ sshd -T -f /etc/ssh/sshd_config -C user=alice,host=x,addr=1.2.3.4 | grep -i forcecommand
forcecommand none
```

One caveat on reading that dump: `sshd -T` still prints
`AllowTcpForwarding yes` / `AllowAgentForwarding yes` for the drop-box user.
That is not a hole — `DisableForwarding` "overrides all other
forwarding-related options" and is reported separately. Do not "fix" the dump.

The per-key `command="…",restrict` prefix is kept anyway. Two independent layers
that each individually suffice is the point; and the key line documents its own
intent when someone reads `authorized_keys` in isolation.

Note what is **not** in that prefix: the common form is `restrict,pty`, and the
`pty` there re-enables terminal allocation that `restrict` just took away.
`rsync` has never needed a terminal. Drop it.

### Trap 2 — the push user's HOME is inside the drop-box

`home = dataDir` is the natural choice: it is where `rrsync` chroots, and it is
where `rrsync` looks for its optional log file. But combined with
`authorizedKeysInHomedir = true` (Trap 1's citation), sshd will read
`<dataDir>/.ssh/authorized_keys` **for this user, on every login**.

`<dataDir>` is owned by the push user. The promoter runs as the push user. So
does every `onPromoted` / `validate` hook. Any of them — or any bug in them —
can write a key into the drop-box's own home and convert the drop-box account
into an interactive account. The uploader cannot reach it directly (`rrsync`
chroots to `incoming/` and rejects `..`), but "the only thing between you and a
shell is that no code you run as this user ever misbehaves" is not a security
boundary.

The Match-level `AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u` removes the
home-directory key store for this user only. Confirmed in the `sshd -T` dump
above: `alice` still gets `%h/.ssh/authorized_keys …`, `dropbox` does not.

### Trap 3 — the `Match` block must be LAST in `sshd_config`

Everything after a `Match` line belongs to that `Match` until the next one or
end of file. `services.openssh.extraConfig` is `types.lines`; nixpkgs appends
it after the generated settings (`sshd.nix:82-89`, `sshd.conf-final`) and
reserves the front for itself with `lib.mkOrder 0` (`sshd.nix:893`). Any other
module writing plain `extraConfig` merges at the default order — which is
*after* an unordered block from this module.

The failure is not subtle, and it is not a warning:

```
/etc/ssh/sshd_config line 29: Directive 'HostKey' is not allowed within a Match block
```

sshd refuses to start, on a host you just deployed remotely. So the block goes
out at `lib.mkOrder 2000`:

```nix
services.openssh.extraConfig = lib.mkOrder 2000 ''
  Match User ${cfg.user}
  …
'';
```

If you have a second module that also appends a `Match` block, order them
explicitly against each other. `lib.mkAfter` (order 1500) is not enough on its
own — two `mkAfter`s are merged in module-evaluation order, which is not
something you want to depend on for whether your sshd boots.

### Trap 4 — `rrsync -wo` blocks *reading*, and nothing else

Read `rrsync` (rsync 3.4.4, `support/rrsync`) rather than trusting the name.

```python
am_sender = command.startswith("--sender ")   # Restrictive on purpose!
if args.wo and am_sender:
    die("reading from write-only server is not allowed")
```

That is the entire meaning of `-wo`. In particular:

- **Deletion is still allowed.** `--delete`, `--delete-before`,
  `--remove-source-files` and friends are only disabled by the *separate*
  `-no-del` flag (`if args.no_del: for opt in long_opts: if
  opt.startswith(('remove','delete')): long_opts[opt] = -1`). Without it, one
  pusher can `rsync --delete` away another pusher's in-flight drop. This module
  passes `-no-del` by default; `allowDelete = true` opts out.
- **Overwriting is still allowed.** `-no-overwrite` (which appends
  `--ignore-existing` server-side) is a third, independent flag. It defaults to
  *off* here on purpose: with it on, a retried or resumed push reports success
  while changing nothing, which is a worse failure than an overwrite. Use
  unique, content-addressed ids instead.
- **Pushes serialise.** Unless `-no-lock` is passed, `rrsync` takes an
  exclusive `flock` on the restricted directory before doing anything:

  ```python
  elif not args.no_lock:
      lock_or_die(args.dir)
  ```

  A second concurrent pusher dies with
  `Another instance of rrsync is already accessing this directory.` If your
  fleet has twenty runners finishing nightly builds within the same minute,
  that is a stream of red CI jobs and no server-side evidence. `serializePushes
  = false` trades that for interleaved uploads. Note that a client which sends
  payload and sentinel as two runs (as it must — Trap 5) releases the lock in
  between either way, so the lock never protects a *drop*, only a *transfer*.

Operational bonus from the same file: `rrsync` opens `rrsync.log` **relative to
the process's working directory**, which sshd sets to the user's home, and only
if the file already exists:

```python
log_fh = open(LOGFILE, 'a') if os.path.isfile(LOGFILE) else None
```

So `touch <dataDir>/rrsync.log && chown <user> <dataDir>/rrsync.log` turns on a
per-connection audit trail of exactly which rsync command line each key ran, and
deleting the file turns it off. No config change, no restart.

### Trap 5 — rsync has no atomic "I am done" signal

The path unit fires when `incoming/<id>/` is *created*, which is at the very
beginning of the transfer. A promoter that acts on that event moves a
half-uploaded tree into `published/` and calls it a build.

There is no rsync-side fix. The contract has to be built:

1. The pusher sends the payload.
2. The first `rsync` **exits**.
3. The pusher sends a sentinel file — alone, in a second `rsync` run.

Steps 1 and 3 must not be merged into one run. rsync gives no ordering guarantee
for files within a single transfer, so a merged run can land the sentinel first.

On the receiving side the worker blocks on the sentinel with a deadline
(`doneTimeoutSec`, default 120 s) and quarantines on expiry:

```
incomplete upload: sentinel '.done' not seen within 120s
```

Three things about that wait that are easy to get wrong:

- **The clock starts when the drop first appears**, not when the last byte
  lands. Size `doneTimeoutSec` against your slowest realistic *whole upload*,
  not against a stall.
- **You cannot watch for the sentinel with a second path unit.**
  `systemd.path(5)`: *"Note that files whose name starts with a dot (i.e.
  hidden files) are generally ignored when monitoring these paths."* A
  dot-prefixed sentinel is invisible to inotify-based path units — which is
  precisely why it is a *good* sentinel name (it can never be mistaken for a new
  drop) and precisely why the worker must poll.
- **Even a non-dot sentinel would not help.** `PathModified=` on
  `incoming/` watches that directory, not its subtree; events inside
  `incoming/<id>/` never reach it.

The worker also requires the sentinel to be a **regular file** (`test -f`), so a
pusher cannot satisfy it with a directory of the same name.

### Trap 6 — the watcher disables itself under load, and the *service's* rate limit is the one that gets you

Two independent rate limits sit in front of this design, and both fail closed by
**turning the watcher off**, not by throttling.

`systemd.path(5)` on the path unit's own limit:

> `TriggerLimitIntervalSec=` … defaults to **2s** … `TriggerLimitBurst=` …
> defaults to **200** … **If the limit is hit, the unit is placed into a failure
> mode, and will not watch the paths anymore until restarted.**

That one is usually fine. The one that bites is the *triggered service's* start
limit, same man page:

> **Unlike other service failures, the error condition that the start rate limit
> is hit is propagated from the service unit to the path unit and causes the
> path unit to fail as well**, thus ending the loop.

systemd's defaults are `DefaultStartLimitBurst=5` per
`DefaultStartLimitIntervalSec=10s`. A single push produces two or three inotify
events on `incoming/` (directory create, then the attribute/mtime writes rsync
does at the end), so **three near-simultaneous pushes** can exceed five starts
in ten seconds. The dispatcher fails, the failure propagates, the path unit dies,
and intake is silently dead until someone reboots the box. There is no alert
because nothing crashed — the artifacts just stop arriving.

So this module:

- sets `StartLimitIntervalSec = 0` on the dispatcher (removing the limit, not
  tuning it — the dispatcher is idempotent and cheap, so a hot loop of it is a
  non-event compared to a dead intake),
- leaves `TriggerLimitBurst` at systemd's own 200 and never lowers it (a
  "tighter for safety" value like `20 per 5s` makes the failure *more* likely,
  which is the opposite of what it looks like it does), and
- ships a **sweep timer** (`sweepInterval`, default 5 min) that runs
  `systemctl reset-failed <name>-watch.path`, restarts it, and re-runs the
  dispatcher. That covers the failed-path case, events lost while units were
  restarting during a deploy, and filesystems where inotify does not fire at
  all (`systemd.path(5)`: "cannot be used to monitor files or directories
  changed by other machines on remote NFS file systems").

The dispatcher itself must therefore be free to run spuriously. It is: it
re-derives the work list from the filesystem every time and skips any id
already present in `published/` or `quarantine/`.

### Trap 7 — the id is an untrusted string used as a path component

The drop id is chosen by the uploader and becomes a path component in `mv` and
`rm -rf`. That combination has exactly one safe ordering: **validate first,
build paths second.**

The natural-looking implementation gets this backwards — it computes
`incoming/$id`, `published/$id`, `quarantine/$id` at the top, and then calls a
`quarantine()` helper for a bad id. The helper's first act is
`rm -rf "$quarantine"`. Reproduced against exactly that shape, with
`id = ../published`:

```console
$ ls published/
build-1  keepme.txt
$ promote.sh '../published'
promote[../published]: quarantining: invalid id: ../published
promote[../published]: WARN: could not move …/incoming/../published to …/quarantine/../published
$ ls published/
ls: cannot access 'published': No such file or directory
```

`$data/quarantine/../published` is `$data/published`. The `mv` failed loudly;
the `rm -rf` had already succeeded silently. Every artifact on the box, gone,
exit status 0.

This is not remotely reachable — instance names come from the dispatcher, which
derives them with `basename` from a glob, so `/` can never appear. It needs root
to trigger. That is not a reason to leave it in: "unreachable today" is a
property of the *caller*, and this unit's caller is one `systemctl start` away
from being a human.

The rules this module applies, in order:

1. **Worker**: validate `%I` against a strict class — non-empty, `≤ maxIdLength`
   (128) characters, all from `[A-Za-z0-9._-]`, no `/`, no whitespace, no
   leading dot — **before constructing a single path**. On failure, log and exit
   0 without touching the filesystem. A drop that arrived through the dispatcher
   can never fail this, so failing it means a human typed something.
2. **Dispatcher**: enumerate `incoming/*/` with `dotglob` and take
   `basename`. A name that fails the same class is quarantined **by its glob
   path** — a real path with no traversal in it regardless of what the uploader
   called the directory — into `quarantine/rejected-<sha256[0:16]>` with a
   `.reason` beside it. `dotglob` matters: without it, a drop named `.evil`
   is invisible to both the glob and (per Trap 5) the path unit, and
   accumulates forever.
3. **Per-id `flock`** in `work/<id>.lock` before any state change, and a
   re-check of every precondition *after* taking it. systemd already refuses to
   run two instances of the same templated unit, so this mostly covers hand-run
   invocations and the sweep firing into a live worker — but it is two lines.
4. `mv -T` rather than `mv` for the promotion. Plain `mv src dst` on an existing
   directory `dst` moves `src` *inside* it; `mv -T` fails instead. That closes
   the check-then-move race that a preceding `[ ! -e "$published" ]` leaves
   wide open.
5. A **post-move re-check** that `realpath published/<id>` is still under
   `realpath published/`, which catches a symlink planted as the published root
   or as the drop's own top level. This is the one condition that exits
   non-zero, because it means an invariant broke rather than an upload being
   bad.

Also note `systemd-escape -- "$id"` in the dispatcher. The `--` stops an id
beginning with `-` from being parsed as a `systemd-escape` option; the resulting
`systemctl start --no-block -- "<prefix>@<esc>.service"` argument always begins
with the unit prefix, so it can never become a `systemctl` flag either.

`%I` (unescaped instance name) is passed to the worker quoted. The class above
excludes whitespace and quotes, so specifier expansion cannot split it into
extra arguments — but if you widen `maxIdLength`'s character class, revisit
this, or switch to `%i` plus `systemd-escape -u` in the worker.

### Trap 8 — `ReadWritePaths=` on its own restricts nothing, and `ProtectSystem=strict` breaks `systemctl`

`systemd.exec(5)`:

> Paths listed in `ReadWritePaths=` are accessible from within the namespace
> **with the same access modes as from outside of it**. … Use `ReadWritePaths=`
> in order to allow-list specific paths for write access **if
> `ProtectSystem=strict` is used**.

A unit with `ReadWritePaths=/srv/artifacts` and no `ProtectSystem=` has bought a
mount namespace and zero restriction. It reads like hardening in a diff and is
not.

The other half of the trap is that you cannot just add `ProtectSystem=strict`
everywhere. Connecting to an `AF_UNIX` socket needs write access to the socket
inode, so under `strict` the whole of `/run` — including
`/run/systemd/private` — is read-only and **every `systemctl` call fails**.

So the units are split by what they need:

| unit | runs as | profile |
| --- | --- | --- |
| `<name>@<id>.service` (worker) | push user | `ProtectSystem=strict` + `ReadWritePaths=[dataDir] ++ extraReadWritePaths` |
| `<name>-dispatch.service` | root | `ProtectSystem=full` — talks to PID 1 |
| `<name>-sweep.service` | root | `ProtectSystem=full` — talks to PID 1 |

If an `onPromoted` hook writes outside `dataDir`, it fails with `EROFS` until
the target is added to `extraReadWritePaths`. That is the intended failure mode.

### Trap 9 — a forced command needs a real login shell

`sshd_config(5)` on `ForceCommand`: *"The command is invoked by using the user's
login shell with the `-c` option."* The same is true of a `command=` in
`authorized_keys`.

A NixOS system user defaults to `shells.nologin`, so every push fails with

```
This account is currently not available.
```

and no other clue anywhere. The module sets `shell = lib.mkDefault
pkgs.bashInteractive`. Giving the drop-box account a real shell is safe here
*because* `ForceCommand` replaces whatever the client asked for — but it is only
safe as long as Trap 1's block is actually present and actually last.

### Trap 10 — promotion is a rename, so keep the tree on one filesystem

`mv` from `incoming/` to `published/` is atomic only within a filesystem. Put
`published/` on a different mount and GNU `mv` silently degrades to
copy-then-delete: readers see a partially populated directory in `published/`
for the duration, and a crash mid-copy leaves it there permanently. There is no
warning. `dataDir` is one option precisely so the four subdirectories cannot
drift apart.

### Trap 11 — `AllowUsers` is global

Restricting sshd to the drop-box account looks like an obvious extra layer:

```nix
services.openssh.settings.AllowUsers = [ cfg.user ];
```

`AllowUsers` is a **global allow-list**. Setting it locks out every other
account on the host, including yours, including your deploy tooling. On a remote
box that is a site visit. It is `manageAllowUsers`, default `false`, and it
should usually stay false — the `Match User` block already constrains the
drop-box account without saying anything about anyone else.

## Usage

Receiver:

```nix
{
  imports = [ ./ssh-write-only-drop-box ];

  services.openssh.enable = true;   # asserted, not implied

  services.sshDropBox = {
    enable = true;
    dataDir = "/srv/artifacts";
    user = "dropbox";
    group = "dropbox";

    pushKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI…  ci-runner-1"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI…  ci-runner-2"
    ];

    doneTimeoutSec = 300;           # slow uploads over a slow uplink

    hookPackages = [ pkgs.jq ];
    validate = ''
      test -f manifest.json || { echo "missing manifest.json"; exit 1; }
      jq -e '.schema == 1' manifest.json >/dev/null \
        || { echo "manifest.json: unsupported schema"; exit 1; }
    '';
    onPromoted = ''touch "$DROPBOX_DATA_DIR/.reindex"'';
  };
}
```

Storage that another unit brings up:

```nix
services.sshDropBox = {
  enable = true;
  dataDir = "/tank/artifacts";
  afterUnit = "wait-for-storage-pool.service";   # After= and Requires=
  pushKeys = [ … ];
};
```

### The client half

`push.sh` in this directory is the other end of the same contract, exposed as
`config.services.sshDropBox.clientPackage` and installable on the receiver with
`installClient = true`:

```console
$ drop-box-push --target dropbox@artifacts.example.org \
                --id "$(date +%s)-$(git rev-parse --short HEAD)-myproject" \
                ./result
```

It stages a dereferenced, writable copy (so a `nix build` result symlink into
the read-only store works), pushes the payload, waits for that rsync to exit,
and only then pushes the sentinel. It mirrors the receiver's id rules locally so
a bad id fails immediately instead of appearing in `quarantine/` ten seconds
later.

Note the remote path: `rrsync` chroots to `incoming/`, so the client writes to
`<target>:<id>/`, never `<target>:incoming/<id>/`. A client that spells it the
second way creates `incoming/incoming/<id>` and is never promoted.

### Operating it

- A rejected drop is `quarantine/<id>` plus `quarantine/<id>.reason` — one line
  of plain text. Nothing is ever deleted on rejection, and no unit goes red;
  `journalctl -u '<name>@*'` and `cat quarantine/*.reason` are the two commands.
- Malformed drop *names* land in `quarantine/rejected-<digest>` since the name
  itself is unsafe to reuse as a path.
- To re-run promotion for one id by hand:
  `systemctl start "<name>@$(systemd-escape -- "$id").service"`.
- To force a full rescan now: `systemctl start <name>-sweep.service`.

## Options

| Option | Default | Effect |
| --- | --- | --- |
| `services.sshDropBox.enable` | `false` | Nothing applies until this is on. |
| `.name` | `"drop-box"` | Prefix for every unit: `<name>-watch.path`, `<name>-dispatch.service`, `<name>@.service`, `<name>-sweep.{service,timer}`. |
| `.dataDir` | *(required)* | Root of `incoming/`, `published/`, `quarantine/`, `work/`. One filesystem — Trap 10. |
| `.user` / `.group` | `"dropbox"` | The push account. Gets `shell = mkDefault bashInteractive` — Trap 9. |
| `.pushKeys` | `[ ]` | Public keys, each written with `command="…",restrict`. Asserted non-empty. |
| `.rrsyncPackage` | `pkgs.rrsync` | Standard `mkPackageOption`. |
| `.allowDelete` | `false` | `false` adds `-no-del`. Trap 4. |
| `.allowOverwrite` | `true` | `false` adds `-no-overwrite` (`--ignore-existing`). Trap 4. |
| `.serializePushes` | `true` | `false` adds `-no-lock`, allowing concurrent pushers. Trap 4. |
| `.sentinel` | `".done"` | Filename the pusher writes last, in its own rsync run. Trap 5. |
| `.doneTimeoutSec` | `120` | Seconds to wait for the sentinel; expiry ⇒ quarantine. Also sets `TimeoutStartSec = n + 60`. |
| `.maxIdLength` | `128` | Longest accepted drop id. |
| `.validate` | `""` | Shell, cwd = the drop, run after the sentinel and before the move. Non-zero ⇒ quarantine; its first 5 lines of output become the reason. |
| `.onPromoted` | `""` | Shell run after a successful move. `DROPBOX_ID`, `DROPBOX_DATA_DIR`, `DROPBOX_PATH`. Failure is logged, not fatal. |
| `.onQuarantined` | `""` | Same, plus `DROPBOX_REASON`. |
| `.hookPackages` | `[ ]` | `PATH` for the three hooks. |
| `.extraReadWritePaths` | `[ ]` | Extra writable paths for hooks under `ProtectSystem=strict`. Trap 8. |
| `.afterUnit` | `null` | Added to `After=` **and** `Requires=` of every unit. |
| `.manageAllowUsers` | `false` | Set `services.openssh.settings.AllowUsers`. Read Trap 11 first. |
| `.installClient` | `false` | Put `<name>-push` in `environment.systemPackages` here. |
| `.clientPackage` | *(read-only)* | The generated client, for a pusher host to consume. |
| `.triggerLimitIntervalSec` | `"10s"` | Path unit `TriggerLimitIntervalSec=`. |
| `.triggerLimitBurst` | `200` | Path unit `TriggerLimitBurst=`; 0 disables. Do not lower — Trap 6. |
| `.sweepInterval` | `"5min"` | Catch-up timer; `null` disables. Trap 6. |

## Testing

`test.nix` is a three-node NixOS VM test of this module. Run it standalone:

```sh
nix-build test.nix --arg pkgs 'import <nixpkgs> { system = "x86_64-linux"; }'
```

or from a flake: `pkgs.callPackage ./modules/ssh-write-only-drop-box/test.nix { }`.

It imports the recipe directly (`./default.nix`) — no adapter, no repo-root
path argument — and takes its addressing from
[`lib/nixos-test-topology`](../../lib/nixos-test-topology)'s `mkTopology`, so no
node carries a framework-assigned address. If you vendor this recipe on its own,
copy that lib too, or replace `topo.nodes.<host>` with your own addressing.

### The negative control is the point

A happy-path test of this module is worthless. "The client pushed a directory
and could not read it back" is satisfied by a half implementation that only
writes `command="…",restrict` into `authorized_keys` — and Traps 1–4 are all
about how that half is trivially bypassable. So the test carries a third node,
`unpaired`: the same push user, the same shell, the module's **own** generated
`command="…",restrict` lines (lifted out of a real `eval-config` of the recipe,
not re-typed), and no `Match` block. Every refusal asserted on `server` is
followed by the same request *succeeding* on `unpaired`.

Two ways to build that control wrong, both hit while writing this test:

* **`services.openssh.extraConfig = lib.mkForce ""` does not strip only the
  Match block.** nixpkgs emits `AuthorizedKeysFile`, `HostKey`, `Port` and
  `Subsystem sftp` through that *same option* at `mkOrder 0`
  (`nixos/modules/services/networking/ssh/sshd.nix:893-914`). Forcing it empty
  breaks public-key authentication outright, and the control then "proves" the
  bypass is impossible — for entirely the wrong reason. The control node
  therefore does not import the recipe at all.
* **`ssh -i <key>` still offers the default identity.** Without
  `IdentitiesOnly=yes`, every "this key must not authenticate" subtest is
  answered by `~/.ssh/id_ed25519` — the legitimate push key — and passes while
  testing nothing.

The subtest that keeps Trap 2 honest asserts its own premise first: it greps the
generated `sshd_config` for a *global* `AuthorizedKeysFile` containing
`%h/.ssh/authorized_keys`. If a future nixpkgs flips
`authorizedKeysInHomedir` to `false`, the premise assertion fails loudly instead
of the subtest silently becoming vacuous.

### What it asserts

1. topology sanity — no `192.168.*` anywhere, one address per interface;
2. a push key **can** rsync a directory in, and the drop is promoted once its
   sentinel lands;
3. that key cannot **list** the drop-box;
4. …cannot **read** anything back (rsync pull, and `scp` of an absolute path);
5. …cannot **overwrite** — with `allowOverwrite = false` the push *succeeds* and
   changes nothing, so the assertion is on the content, not the exit status;
6. …cannot **delete**;
7. …cannot run an **arbitrary command**, and cannot get a shell;
8. **pairing:** an unrestricted key in the managed `authorized_keys` file gets
   neither a command nor a TCP forward — and the same key on `unpaired` gets
   both;
9. **pairing:** a key planted in the push user's own `~/.ssh/authorized_keys`
   does not authenticate — and does on `unpaired`;
10. **pairing:** the `Match` block is the last thing in `sshd_config`, with
    nothing unindented after it (Trap 3);
11. the "no atomic done signal" trap: a drop whose sentinel never arrives is
    never promoted and is quarantined with a reason once `doneTimeoutSec`
    passes;
12. a malicious id is rejected rather than used as a path component — `..` in
    the remote path refused by the transport, an absolute remote path re-anchored
    inside the chroot, a leading-dot id quarantined under a digest of its name,
    and a hand-started `<name>@<id>.service` with `/` or a leading dot in its
    instance name touching nothing.

### Verified by mutation

Every group above was watched **failing** against a deliberately broken copy of
the recipe before being trusted:

| Mutation | Test outcome |
| --- | --- |
| `Match` block emptied (forced command in the key only) | subtest 8 fails: the unrestricted key runs `id` on `server` |
| `mkAuthorizedKey = k: k` (no `command=`, no `restrict`) | eval-time assertion fails; the derivation refuses to build |
| `-wo` dropped from the `rrsync` flags | subtest 3 fails: `--list-only` succeeds |
| sentinel wait removed | subtest 2 fails: the drop is promoted out from under the second rsync run and the push exits 3 |
| deadline quarantine replaced by `break` | subtest 11 fails: `published/stale-drop` exists — the sentinel-less drop was promoted |
| `id_is_safe` bypassed in `dispatch.sh` | subtest 12c fails: `.evil` is dispatched as a drop id instead of being quarantined under a digest |
| `id_is_safe` bypassed in `promote.sh` | subtest 12d fails: the worker acts on id `../published` and resolves it against the published root |

If you extend the test, extend this table. A subtest nobody has watched fail is
a claim, not evidence.

## Caveats

- **The hooks run as the push account**, inside the drop-box's own directory
  tree, with whatever `hookPackages` you gave them. Trap 2 removed the
  home-directory key store, but a hook is still the most privileged thing on
  this box that touches uploader-controlled bytes. Treat `validate` as parsing
  hostile input, because it is.
- **A re-push to an already-promoted id is quarantined**, not merged. That is
  deliberate — the alternative is a published artifact whose contents change
  under readers — but it means ids must be unique per push. A
  `<unix-ts>-<short-sha>-<project>` shape fits the character class and sorts
  usefully.
- **Nothing here garbage-collects.** `published/` and `quarantine/` grow without
  bound. Add a `systemd.tmpfiles` age rule or a timer of your own; the module
  does not guess a retention policy.
- **`installClient` puts the client on the receiver**, which is only useful when
  the receiver also builds. Pusher hosts should take `clientPackage` or vendor
  `push.sh`.
- **Quarantine reuses the drop id.** A second bad push with the same id replaces
  the first (`rm -rf` on a *validated* id, then `mv -T`). If you need every
  rejection preserved, move them aside from `onQuarantined`.
- **`rrsync` is Python.** `pkgs.rrsync` pulls in a `python3` closure and, for
  brace-expansion support, `python3Packages.braceexpand`. On a minimal image
  that is a few tens of MB you may not have budgeted for.
- **This module drives no firewall rules.** Intake rides the SSH port you
  already have open, so there is no `networking.firewall.extraCommands` /
  nftables-backend conflict to worry about.

## See also

- [`spool-dir-credential-broker`](spool-dir-credential-broker.md) — the mirror
  image: a shared spool directory where *producers* are unprivileged and one
  watcher holds the secret. Same "drop a file, a unit picks it up" shape, same
  sentinel and validation concerns.
- [`push-observability-receiver`](push-observability-receiver.md) — the same
  push-not-pull posture for logs and metrics rather than artifacts.

What is deliberately **not** here: rendering an index over `published/`. Serving
the drops is a product decision (schema, theme, access control, cache headers)
with no general answer, and welding one into the intake makes the intake
untestable on its own. `onPromoted` is the seam — have it touch a file that your
own site generator watches, or call your generator directly.
