# per-uid-egress-lockdown

Run an untrusted program — a code agent, a scraper, a vendored build script you
did not read — as **its own uid**, inside bubblewrap, with **no network at all
except a loopback CONNECT proxy that enforces a domain allowlist**.

The allowlist is enforced *twice*, and the second one is the only one that
counts.

## The problem

"Give this thing internet access to exactly these domains" is normally
implemented as a proxy plus `HTTPS_PROXY` in the environment. That is a
**convention**, not a control. Anything the program runs — a package manager's
post-install hook, a vendored binary, a Python module that builds its own
`urllib3` pool — can simply not read the variable, open its own socket, and go
wherever it likes. Your allowlist becomes a suggestion the well-behaved parts of
the program follow.

The fix is to make "not using the proxy" mean "no network", in the kernel:

| Layer | What it enforces | How it is bypassed |
| --- | --- | --- |
| squid `http_access allow CONNECT <allowlist>` | *which* domains | ignore `HTTPS_PROXY` |
| nftables `output` chain, `meta skuid <uid> drop` | *that the proxy is used at all* | you would need another uid |

Layer 2 is what makes layer 1 real. With the drop rule in place, a program that
ignores the proxy env vars gets `ENETUNREACH` on its very first `connect()` —
not the open internet.

## Trap 1 — the proxy MUST run as a different uid

This is the corollary that catches people, and it is easy to get wrong in a way
that silently reverts the whole design.

The drop rule is `meta skuid <sandbox uid> drop`. If the proxy runs as *that same
uid*, the proxy's own outbound packets match the drop rule and the proxy cannot
reach anything. The obvious "fix" is to punch a hole — allow `tcp dport 443` for
the uid — and now the sandboxed program has direct HTTPS to the entire internet.
You have reintroduced exactly the bypass the table existed to close, and
everything still *looks* like it works, because the proxy also still works.

So: two uids, both pinned, and the module hard-asserts they differ:

```
services.perUidEgressLockdown: uid (60900) and proxyUid must differ.
```

The proxy uid gets its own, much narrower ruleset — DNS plus the CONNECT target
ports, nothing else — so a compromised squid is not a general exfiltration
channel either:

```
meta skuid 60900 oifname "lo" ct state established,related accept
meta skuid 60900 oifname "lo" tcp dport 3128 accept
meta skuid 60900 drop

meta skuid 60901 ct state established,related accept
meta skuid 60901 udp dport 53 accept
meta skuid 60901 tcp dport 53 accept
meta skuid 60901 tcp dport 443 accept
meta skuid 60901 oifname "lo" accept
meta skuid 60901 drop
```

Note the sandbox uid has **no DNS**. It cannot resolve anything; resolution
happens inside the proxy as part of `CONNECT host:443`. The failure signature
when a program tries to resolve directly is a *name resolution* error
(`EAI_AGAIN`, `getaddrinfo failed`, `ENOTFOUND`), never a connection error —
which reads like a broken DNS setup and sends people off debugging
`resolv.conf`. It is the lockdown working.

### Why `uid`, not a dynamic user

`meta skuid` matches a **number**. `DynamicUser = true` or an unpinned
`users.users.<n>.uid = null` allocates from a pool and can renumber across
rebuilds or across hosts, at which point the table is filtering a uid nobody
runs as — fail-open, with no error anywhere. Both uids in this module are
required to be explicit integers, and they are the module's real interface.

`skuid` is the **kernel** uid that owns the socket. bubblewrap here uses
`--unshare-all --share-net`, so the sandbox does get a user namespace, and a
program can make itself uid 0 *inside* it. That changes nothing: the socket's
owner in the initial user namespace is still the sandbox uid, so the drop rule
still matches. Namespace root does not buy egress.

## Trap 2 — `deny CONNECT !SSL_ports` and `cache deny all`

A domain allowlist on a CONNECT proxy without a **port** allowlist is an
arbitrary-port tunnel to every allowlisted host. `CONNECT allowed.example:22`
is an SSH session; `:25` is a mail relay; `:9000` is whatever that host also
runs. And a proxy without `cache deny all` quietly accumulates a copy of
everything the sandbox fetched, on disk, owned by the proxy user.

Both directives are in the generated config, and the ordering matters — the
deny comes **before** the allow:

```
acl <name>_allowed dstdomain .example.com
acl SSL_ports port 443
acl CONNECT method CONNECT
http_access deny CONNECT !SSL_ports
http_access allow CONNECT <name>_allowed
http_access deny all
cache deny all
```

Verified against a live squid 7.6 from stock nixpkgs (access log, verbatim):

```
TCP_TUNNEL/200  CONNECT allowed.example:443   <- allowlisted domain, allowed port
TCP_DENIED/403  CONNECT other.example:443     <- not on the allowlist
TCP_DENIED/403  CONNECT allowed.example:22    <- allowlisted domain, WRONG port
TCP_DENIED/403  GET http://allowed.example/   <- plain HTTP through the proxy
```

That last line is a property worth keeping: because the only `allow` rule is
`allow CONNECT …`, non-CONNECT methods are refused outright. The sandbox cannot
speak cleartext HTTP through the proxy at all — everything is an end-to-end TLS
tunnel that squid never terminates. Which in turn means **no SSL-bump, no
certificate generation, no CA to install**, and the sandbox validates the real
server certificate itself.

## Trap 3 — the source tree is read-only and lives outside the writable state

The sandboxed program's own code (`sourceDir`) is bind-mounted **read-only**,
and it is kept **outside** `stateDir`, the one place the sandbox can write.

If the program can write its own source tree — because the checkout sits inside
the state directory, or because it was bind-mounted read-write "so it can update
itself" — then one compromised run rewrites what the *next* run executes. The
sandbox has bought you a delay, not a boundary: the attacker gets the same
credentials, the same allowlist, and now also code execution that survives you
noticing.

Writable outputs are punched *into* the read-only tree as individual mounts:

```nix
sourceDir = "/var/lib/agent-src/checkout";     # read-only
stateDir  = "/var/lib/agent";                  # the only writable place
launcher.stateMounts = {
  "/src/out"        = "out";        # -> /var/lib/agent/out
  "/src/.auth.json" = ".auth.json"; # -> /var/lib/agent/.auth.json
};
```

The module asserts `sourceDir` is not under `stateDir`.

Note bubblewrap's requirement here: `--bind` of a *file* needs the target to
already exist on both sides. That is what `stateFiles` is for — the launcher
touches each one into existence before the run, or bwrap fails with a bare
`Can't find source path`.

## Trap 4 — secrets fail at run time, not at eval time

The tempting way to wire a secret into a module like this is a `builtins.pathExists`
guard on the encrypted file, or an assertion that the decrypted path exists.
Both put a *secret's* lifecycle on the critical path of the *host's evaluation*:
forget to `git add` the new `.age` file, or rotate a key, and every deploy of
that machine fails at eval — including the deploys that have nothing to do with
this sandbox.

This module never reads secrets at eval time. `launcher.secretEnvironment` and
`launcher.secretFiles` take *paths*, and the generated wrapper checks them at
run time:

```bash
[ -r /run/secrets/api-token ] || { echo "missing or unreadable secret: /run/secrets/api-token" >&2; exit 1; }
```

A missing secret breaks this one command, with a message naming the file. The
host still builds, still deploys, still boots.

Prefer `secretFiles` (bind-mounted read-only into the sandbox) over
`secretEnvironment` when the program can take a path: `secretEnvironment` reads
the file with `$(cat …)`, so the value transits the launcher's own argv.

## Trap 5 — a bare sudoers command permits *any* arguments

The launcher is meant to be invoked as the sandbox user, typically:

```
sudo -u agent agent
```

A sudoers entry of the form `alice ALL=(agent) NOPASSWD: /nix/store/…/bin/agent`
permits that command **with any arguments whatsoever**. If your launcher
forwards `"$@"` anywhere — into the sandboxed command, into a `--setenv`, into
the tool's own CLI — that is an injection surface handed to whoever is on the
`sudo.users` list.

`sudo.forbidArguments` (default `true`) appends the empty-string argument spec,
which is sudoers for "this command, with no arguments at all":

```
alice ALL=(agent) NOPASSWD: /nix/store/…/bin/agent ""
```

Set it to `false` only if the launcher genuinely takes arguments *and* you have
audited what it does with them.

## Trap 6 — sharing the host network namespace is not free

This sandbox deliberately does **not** use `--unshare-net`: it needs to reach
the proxy on the host's loopback. (For total isolation with no allowlist at all,
see [`network-isolated-editor`](network-isolated-editor.md), which does use
`--unshare-net`.) Sharing the host netns has two consequences:

- **Other loopback services are in reach of the packet filter, and only the
  packet filter.** Everything on `127.0.0.1` — a database, an admin UI, another
  proxy, a metrics endpoint — is one `connect()` away. The `meta skuid <uid>
  drop` rule is what stops it, and every entry you add to `extraLoopbackPorts`
  is a hole punched straight through to a host service. Keep it empty.
- **Abstract-namespace AF_UNIX sockets are NOT filtered.** They live in the
  network namespace, but nftables cannot match them. A session bus, an
  `@/tmp/.X11-unix/X0`, an agent socket bound to the abstract namespace is
  reachable by the sandbox regardless of every rule in this module. If the host
  has abstract sockets that matter, this recipe is not enough on its own — you
  want a real network namespace plus a socket relay, or a VM.

## Trap 7 — the table is fail-open, and `flushRuleset` will open it

The chain is `policy accept` with explicit per-uid drops, deliberately: this
table narrows exactly two uids and never touches anyone else's traffic, so it
composes with whatever firewall the host already runs. The price is that
**if the table is not there, nothing is filtered**.

`networking.nftables.flushRuleset` runs `flush ruleset` on every start *or
reload* of `nftables.service` — including reloads triggered by entirely
unrelated firewall changes. That deletes this module's table, and the sandbox
uid is unfiltered until `<name>-egress-lockdown.service` next runs. The module
emits a `config.warnings` entry when it sees that combination. (It defaults on
for hosts with a `system.stateVersion` older than 23.11, and whenever
`networking.nftables.ruleset`/`rulesetFile` is used.)

Check the table is actually loaded before trusting it:

```
nft list table inet <name>-egress
```

Disabling the module removes its unit from the config entirely, so nothing ever
runs the `ExecStop`; the table lingers in the kernel until you
`nft delete table inet <name>-egress` by hand. Harmless (it filters uids that no
longer exist) but worth knowing.

## Trap 8 — squid 7 removed `dns_v4_first`

If you are porting an older config: `dns_v4_first on` is **obsolete in squid
7.x**. With stock nixpkgs squid 7.6 it produces, on every start:

```
ERROR: Directive 'dns_v4_first' is obsolete.
dns_v4_first : Remove this line. Squid no longer supports preferential treatment of DNS A records.
```

It is not fatal — squid starts and serves normally — and, notably, **`squid -k
parse` still exits 0**, so upstream's `services.squid.validateConfig` (which is
exactly `squid -k parse -f`, `nixos/modules/services/networking/squid.nix:19`)
does not catch it either. It is just a permanent error line in your cache log.
This module does not emit it; put it in `proxy.extraConfig` if you are pinned to
squid ≤ 6 and want it.

## What upstream nixpkgs does not do

- **There is no per-uid egress option in NixOS.** `networking.firewall` has no
  owner/uid match of any kind. The only uid-owner rules in the entire NixOS
  module set are in `nixos/modules/services/networking/sslh.nix:246` (and its
  IPv6 twin at 265) — and those go through `networking.firewall.iptablesCommands`,
  which the nftables backend hard-rejects
  (`nixos/modules/services/networking/firewall-nftables.nix:65-70` asserts
  `extraCommands == ""` / `extraStopCommands == ""`). `biboumi.nix:225` contains
  a *comment* sketching `add rule inet filter output meta skuid biboumi tcp
  accept` as something the reader might write themselves. That is the whole of
  upstream's per-uid egress story.

- **`services.squid` cannot be used for this.** Three independent blockers, all
  in `nixos/modules/services/networking/squid.nix`:
  1. It is a **singleton** — one `services.squid.enable`, one unit, hard-coded
     `/run/squid.pid` and `/var/log/squid`. You cannot run a per-sandbox
     instance, let alone two.
  2. Its unit has **no `User=`** (lines 186–206). Squid starts as **root** and
     drops the worker to the `squid` account internally via
     `cache_effective_user squid squid` (line 85). The uid that owns the master
     process is 0, and "uid 0" is not something a per-uid drop rule can be
     written around. There is no `NoNewPrivileges`, `ProtectSystem`, or
     `ProtectHome` either.
  3. Its default config ends in `http_access allow localnet` /
     `http_access allow localhost` (lines 95–96), where `localnet` is all of
     RFC1918 plus link-local plus `fc00::/7` (lines 38–43). Out of the box that
     is an open proxy for your entire LAN.

  So this module runs squid directly: `ExecStart = squid -f <conf> -N` under
  `User=`/`Group=` of a dedicated account, `RuntimeDirectory`,
  `ProtectSystem = "strict"`, `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`.
  `-N` keeps it in the foreground so systemd supervises the real process;
  `pid_filename` has to point inside the runtime directory, because
  `ProtectSystem = "strict"` makes squid's default `/run/squid.pid` unwritable.

- **Nothing upstream wires bubblewrap into a NixOS service.** `bubblewrap`
  appears in exactly one NixOS module (`programs/opengamepadui.nix`), as a
  runtime dependency of a game launcher.

- **`shutdown_lifetime` defaults to 30 seconds** and squid honours it on
  SIGTERM. Left alone, every `systemctl restart` of the proxy — i.e. every
  deploy — stalls for half a minute. This module defaults it to `1 seconds`.

## Usage

```nix
{ pkgs, ... }:
{
  imports = [ ./per-uid-egress-lockdown ];

  services.perUidEgressLockdown = {
    enable = true;
    name   = "agent";          # names the units, the nft table, /run/agent-squid

    uid      = 60900;          # pinned: the nft rules match these numbers
    proxyUid = 60901;          # MUST differ from uid

    allowedDomains = [ ".api.example.com" ];

    stateDir     = "/var/lib/agent";        # the only writable place
    stateSubdirs = [ "out" "tmp" ];
    stateFiles   = [ ".auth.json" ];
    sourceDir    = "/var/lib/agent-src/checkout";   # read-only, outside stateDir

    launcher = {
      command   = "exec npm run --silent build";
      packages  = with pkgs; [ coreutils bash nodejs_22 ];
      workingDirectory = "/src";
      stateMounts = {
        "/src/out"        = "out";
        "/src/.auth.json" = ".auth.json";
      };
      environment = {
        SSL_CERT_FILE       = "/etc/ssl/certs/ca-bundle.crt";
        NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/ca-bundle.crt";
      };
      secretEnvironment.API_TOKEN = "/run/secrets/agent-api-token";
    };

    sudo.users = [ "alice" ];   # may run `sudo -u agent agent`
  };
}
```

The sandbox starts from `--clearenv`, so **nothing** is inherited. TLS-using
programs generally need `SSL_CERT_FILE` set explicitly (Node additionally wants
`NODE_EXTRA_CA_CERTS`); the launcher always binds `/etc/ssl` read-only so the
bundle is there to point at.

### Staging read-only inputs

When the sandbox needs to read trees that live somewhere awkward — a home
directory, a shared checkout area — `mountStage` bind-mounts them read-only into
a root-owned directory first, so the sandbox never has to be able to traverse
the parent:

```nix
mountStage = {
  enable  = true;
  sources = [ "/srv/mirrors/upstream-a" "/srv/mirrors/upstream-b" ];
};
launcher.stageMountPoint = "/stage";   # -> /stage/upstream-a, /stage/upstream-b
```

The staging unit is a `oneshot` with `RemainAfterExit`; it is idempotent
(`mountpoint -q || mount --bind -o ro`) and unmounts in `preStop`. A source that
does not exist is skipped rather than failing the unit.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Turn everything on. |
| `name` | `"sandbox"` | Prefix for units (`<name>-squid`, `<name>-egress-lockdown`), the nft table `inet <name>-egress`, the squid ACL, `/run/<name>-squid`, and the wrapper binary. |
| `user` / `uid` | `name` / `60900` | The sandboxed program's account. **`uid` must be pinned.** |
| `proxyUser` / `proxyUid` | `"<name>-proxy"` / `60901` | The proxy's account. Must differ from the above. |
| `allowedDomains` | `[ ]` | squid `dstdomain` allowlist. Leading dot = domain + subdomains. |
| `extraLoopbackPorts` | `[ ]` | Extra host-loopback TCP ports the sandbox uid may reach. Each one is a hole; see Trap 6. |
| `proxy.package` | `pkgs.squid` | Stock nixpkgs squid is sufficient — no SSL-bump features are used. |
| `proxy.listenAddress` / `.port` | `"127.0.0.1"` / `3128` | Where the proxy listens. Loopback only. |
| `proxy.sslPorts` | `[ 443 ]` | Ports CONNECT may target. |
| `proxy.egressPorts` | `[ 443 ]` | Ports the *proxy uid* may reach off-box (nftables). |
| `proxy.allowDns` | `true` | Let the proxy uid do DNS. The sandbox uid never can. |
| `proxy.accessLog` | `stdio:/run/<name>-squid/access.log squid` | tmpfs by default: no persistent request log. `stdio:/dev/stdout squid` sends it to the journal instead. |
| `proxy.cacheLog` | `/run/<name>-squid/cache.log` | Must be inside the runtime directory. |
| `proxy.shutdownLifetime` | `"1 seconds"` | Upstream default is 30s; see above. |
| `proxy.extraConfig` | `""` | Extra squid directives, appended verbatim. |
| `stateDir` | `/var/lib/<name>` | The only writable path. |
| `stateSubdirs` / `stateFiles` | `[ ]` | Created/touched before the run. |
| `manageDirectories` | `true` | Emit the `systemd.tmpfiles` rules. Off if you provision these via impermanence / a dataset / your own ruleset. |
| `sourceDir` | `null` | Read-only source tree. Asserted to be outside `stateDir`. |
| `mountStage.{enable,dir,sources,unitName}` | off | Root-owned read-only bind-mount stage. |
| `launcher.enable` | `true` | Build and install the bubblewrap wrapper. |
| `launcher.package` | `null` | Escape hatch: bring your own launcher (see below). |
| `launcher.binName` | `name` | Command name on `PATH`. |
| `launcher.command` | `""` | Shell run inside the sandbox (`bash -c`). |
| `launcher.packages` | `[ ]` | Makes up `PATH` inside the sandbox. |
| `launcher.sourceMountPoint` / `.stageMountPoint` / `.homeMountPoint` | `/src` / `/stage` / `/state` | Where things appear inside. |
| `launcher.workingDirectory` | `"/"` | `--chdir`. |
| `launcher.stateMounts` | `{ }` | in-sandbox path -> `stateDir`-relative path, read-write. |
| `launcher.roMounts` | `{ }` | in-sandbox path -> host path, read-only. |
| `launcher.environment` | `{ }` | Env inside the sandbox (starts from `--clearenv`). |
| `launcher.secretEnvironment` | `{ }` | `VAR` -> file, read at run time. |
| `launcher.secretFiles` | `{ }` | in-sandbox path -> host secret file, bind-mounted read-only. |
| `sudo.users` | `[ ]` | Users who may run the launcher as `user`, NOPASSWD. |
| `sudo.forbidArguments` | `true` | Append `""` to the sudoers command spec; see Trap 5. |

### `launcher.package` — bringing your own

The generated launcher covers the common shape, but the *inner* command of a
real workload often needs setup the option surface does not express. Setting
`launcher.package` to your own derivation (providing `bin/<binName>`) keeps
everything else — the two accounts, the nftables table, the proxy, the staging
mounts, the sudo rule — and replaces only the wrapper.

The kernel lockdown does not care which wrapper you use: it is bound to the
uid, not to this module's script. What you take on is reproducing the *sandbox*
properties yourself — read-only source, `--clearenv` plus the proxy variables,
no argument passthrough.

## Firewall backend

This module does **not** use `networking.firewall.extraCommands` /
`extraStopCommands`, so it works on **both** the iptables and the nftables
backend without an assertion. It owns a self-contained `inet <name>-egress`
table applied by its own oneshot unit (`nft -f <ruleset>`, one atomic netlink
transaction), and it stays out of `networking.nftables.tables` — which deletes
and recreates every table it declares on each reload. See
[`egress-filter`](egress-filter.md) for the same finding in a
per-*interface* (rather than per-*uid*) filter, and for what to do when the
allowlist has to be expressed as IPs instead of a CONNECT target.

Ordering: `<name>-egress-lockdown.service` is `after = [ "firewall.service" ]`
and `wantedBy = [ "multi-user.target" ]`. It is a `oneshot` with
`RemainAfterExit`, so a `switch` that does not restart it leaves the running
table alone.

## Test

`test.nix` is a four-node NixOS VM test built on
[`nixos-test-topology`](../../lib/nixos-test-topology). Run it with:

```sh
nix-build test.nix --arg pkgs 'import <nixpkgs> { system = "x86_64-linux"; }'
```

or, from a flake, `pkgs.callPackage ./modules/per-uid-egress-lockdown/test.nix {}`.

It boots a confined host, a router, an allowlisted origin and a
non-allowlisted origin. The two origins sit on a **different subnet** from the
confined host, so every packet toward them has to transit the router — on one
subnet the client would ARP the origin directly, the router would never see the
traffic, and the filtering assertions would be tautologies.

What it asserts, and why none of it can be satisfied by accident:

| # | claim | how it is instrumented |
|---|-------|------------------------|
| 0 | `uid == proxyUid` is rejected | eval-time; the module's own assertion must fire |
| 1 | confined uid **reaches** an allowlisted destination via the proxy | body matches, squid logged the CONNECT, the router forwarded packets, and the **proxy** uid — not the confined one — was the sender |
| 2 | confined uid **cannot** reach a non-allowlisted destination via the proxy | squid logs `TCP_DENIED`, and the router forwarded **zero** packets toward it |
| 3 | confined uid **cannot bypass** the proxy | direct `curl --noproxy '*'` to the destination IP hangs and times out |
| 4 | a different uid is unaffected | `root` and an ordinary uid run the *identical* command against the *identical* address and succeed, including to the non-allowlisted origin |
| 5 | the shipped bubblewrap launcher does 1–3 in one real run | reads what the sandboxed program wrote to its state dir |
| 6 | confined uid cannot resolve names either | DNS is the proxy uid's privilege |

Subtest 3 is the one worth copying. `curl` failing is satisfied by a typo in an
address, a missing route, or a dead server, so the failure alone proves nothing.
It is pinned down by **two counters on opposite sides of the boundary**: an
`output`-hook counter on the confined host at priority `-300` (i.e. *before* the
module's chain at priority `0`), matching `meta skuid <confined uid>`, and the
topology library's `forward`-hook counter on the router. The subtest requires
the first to be **non-zero** — the process really did emit a SYN at the
destination — and the second to be **zero** — nothing left the host. A drop that
is not in the packet path fails one or the other.

That is not theoretical. Mutating the module's chain from
`hook output` to `hook forward` — leaving a table that still loads and still
reads `meta skuid <uid> drop` in `nft list table` — keeps subtests 1, 2 and the
"table is loaded" check green and fails subtest 3 with
`the confined uid reached the origin directly: 'ALLOWED-ORIGIN-PAYLOAD'`.
Removing the module's `uid != proxyUid` assertion fails the test at *eval*;
nixpkgs alone only emits a `Duplicate uid` **trace** for that configuration, so
the module's assertion is the only thing that stops it.

On the "the proxy must run as a different uid" corollary: that is caught at eval
(subtest 0), before a VM boots. If the assertion did not exist, the runtime test
would still fail — with a shared uid the sandbox's `drop` rule matches squid's
own egress and subtest 1 fails — but it would fail as *"the proxy is broken"*,
not as *"the lockdown is void"*. The eval check is what names the actual fault.

## Related recipes

- [`network-isolated-editor`](network-isolated-editor.md) — the all-or-nothing
  sibling: bubblewrap with `--unshare-net` and no proxy at all. Use it when the
  answer is "no network", not "these domains".
- [`egress-filter`](egress-filter.md) — domain allowlist for a whole *interface*
  (VM bridge, container network), enforced as a live IP set.
- [`nixos-hardening-tiers`](nixos-hardening-tiers.md) — host-level tiers; note
  its knobs and this module's `systemd` hardening are independent decisions.

## Caveats

- **`dstdomain` is only as tight as the domain.** `.example.com` matches every
  subdomain. If an allowlisted host runs an open redirect, a proxy endpoint, or
  user-controlled subdomains, egress is effectively wider than the list reads.
- **The proxy sees hostnames, not content.** CONNECT tunnels are opaque; there
  is no inspection of what flows through an allowed tunnel, by design (see the
  no-SSL-bump note above). This bounds *where* data can go, not *what* goes
  there.
- **No egress accounting or rate limiting.** Add `delay_pools` via
  `proxy.extraConfig` if you need it.
- **The access log is on tmpfs by default** — it does not survive a reboot.
  That is deliberate (no long-term record of what the sandbox fetched) but it
  also means no forensic trail; set `proxy.accessLog = "stdio:/dev/stdout
  squid"` to route it to the journal.
- **Nothing here confines the *filesystem* beyond the bind mounts you declare.**
  `/nix/store` is bound read-only in full, as it must be for anything to run.
- **The `stateDir` is shared across runs.** Two concurrent invocations of the
  launcher write to the same directory; the module does not lock. Wrap it in a
  systemd unit or a flock if that matters.
