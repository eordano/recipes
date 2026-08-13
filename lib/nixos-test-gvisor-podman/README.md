# nixos-test-gvisor-podman

A NixOS-test node configuration that runs podman with the gVisor (`runsc`) OCI
runtime, and lets a container under `runsc` reach a service on the VM node it
runs in. `mkNode` returns a module you import into a test node; the worked
example is a complete single-node test that proves the workload is really on
gVisor and not on the host kernel.

```nix
node = (import ./lib/nixos-test-gvisor-podman).mkNode { };

nodes.machine = { ... }: { imports = [ node ]; };
```

```sh
podman run --rm --runtime=runsc \
  --network=slirp4netns:allow_host_loopback=true <image> ...
```

## The problem

Three traps sit between "add gvisor to the test" and a green test, and each one
masks the next: you only meet the second after fixing the first. None of the
three failures names the thing that is actually wrong. They are presented below
in the order a person hits them, with the exact error text, because those
strings are what gets pasted into a search engine.

Everything below was verified against nixpkgs 26.11 (`nixos-unstable`,
2026-08-07) with a test that now passes -- podman 5.8.4, gVisor 20260406.0,
slirp4netns 1.3.4.

## Trap 1 -- registering the runtime by hand does not even EVALUATE

The runtime has to be named in `/etc/containers/containers.conf`, so the obvious
move is to write that file:

```nix
environment.etc."containers/containers.conf".text = ''
  [engine]
  [engine.runtimes]
  runsc = [ "${pkgs.gvisor}/bin/runsc" ]
'';
```

`virtualisation.podman.enable` turns on `virtualisation.containers`, which
generates the same file from `virtualisation.containers.containersConf.settings`
and writes it through `environment.etc`. Two definitions of one option, neither
a `mkDefault`:

```
error: The option `nodes.machine.environment.etc."containers/containers.conf".source' has conflicting definition values:
- In `<nixpkgs>/nixos/modules/system/etc/etc.nix': <derivation etc-containers-containers.conf>
- In `<nixpkgs>/nixos/modules/virtualisation/containers.nix': <derivation containers.conf>
```

(`<nixpkgs>` stands in for the store path of your nixpkgs checkout.)

This is an evaluation failure, not a test failure: nothing builds, no VM starts.
Note the trap inside the trap -- the option named in the error is `.source`,
while what you wrote was `.text`; `.text` is desugared into a `.source`
derivation by `etc.nix`, so grepping your own tree for `.source` finds nothing.

The fix is the supported option:

```nix
virtualisation.containers.containersConf.settings.engine.runtimes.runsc =
  [ "${pkgs.gvisor}/bin/runsc" ];
```

The value is a **list** of paths, not a string. Set
`containersConf.settings.engine.runtime = "runsc"` as well (`mkNode`'s
`makeDefault`) if you want `--runtime=` to become optional.

`mkNode` merges those two with `lib.recursiveUpdate`, not `//`: `//` is shallow,
so an `{ engine.runtime = ...; }` on the right-hand side would replace the whole
`engine` attrset and silently drop `engine.runtimes`.

## Trap 2 -- podman exits 127: `could not find slirp4netns`

With the runtime registered, the test evaluates and the VM boots, and a
`podman run --network=slirp4netns` fails with exit code **127** and:

```
Error: could not find slirp4netns, the network namespace can't be configured: exec: "slirp4netns": executable file not found in $PATH
```

`slirp4netns` is a separate executable that podman looks
up on `PATH` at run time. The podman module does wire it in, but only when
`containersConf.settings.network.default_rootless_network_cmd == "slirp4netns"`
(`<nixpkgs>/nixos/modules/virtualisation/podman/default.nix`, in the `package`
option's `apply`), and that condition is about the *rootless default*, not about
an explicit `--network=slirp4netns` on a root container -- which is what a test
script normally runs. So:

```nix
environment.systemPackages = [ pkgs.slirp4netns ];
```

Exit 127 is the shell's "command not found", so it is easy to read this as
"podman itself is missing" or as a broken test-script quoting problem. It is
neither; podman is present and it is *podman* that could not find a command.

One practical detail when this happens inside a test: the message is on the
node's stderr, so `rc, out = machine.execute(...)` returns `rc == 127` with an
**empty** `out`. The text appears in the test log as a `machine # Error: ...`
console line. Assert on the return code, and read the message from the log.

## Trap 3 -- reaching the node's LOOPBACK needs `allow_host_loopback=true`, or wget exits 4

Now the container starts, gets an address, and runs. A fetch of a service
listening on the VM node's loopback still fails:

```
podman run --network=slirp4netns ... wget -q -O - http://10.0.2.2:8080/
```

exits **4** -- wget's "network failure". podman reports nothing at all: the
container is created, started, dies with status 4 and is removed, and the
journal shows an ordinary container lifecycle. There is no message to search
for, which is why this reads as a firewall rule, a service bound to the wrong
address, or a routing bug in the test topology -- and that is where the time
goes.

slirp4netns gives the container its own namespace on `10.0.2.0/24` -- container
`10.0.2.100`, gateway `10.0.2.2` -- and `10.0.2.2` is how the container reaches
back into the namespace podman was invoked from, i.e. the VM node itself.
Traffic to that gateway address is dropped unless the flag is on:

```
--network=slirp4netns:allow_host_loopback=true
```

The flag governs that gateway address, not the node in general. A service bound
to an address the node holds on a real interface is reachable from a plain
`--network=slirp4netns` container with no flag at all: probed with a second
node address on `eth1` and a server on `0.0.0.0`, the fetch returns the body.
`allow_host_loopback=true` is what you need when the service is on the node's
*loopback* -- which is the case the example pins down, and the usual case for a
service a test just started. One address that is *not* a way in: a NixOS test
node's own `eth0` is `10.0.2.15`, which sits inside slirp4netns's own
`10.0.2.0/24`, so the container treats it as on-link and the fetch exits 4 like
the gateway does.

The flag is per-`podman run`, not something the node configuration can turn on,
which is why `mkNode` cannot fix this trap for you and exports the string
instead. The worked example asserts both directions -- plain `slirp4netns`
must give exit 4, `allow_host_loopback=true` must return the body -- so the flag
is the only variable between the two.

## Prerequisite: KVM, but not *nested* KVM

The NixOS test boots its node under QEMU, so the machine that executes the test
wants `/dev/kvm` like any other NixOS test. gVisor on top of that does **not**
need nested KVM. `runsc`'s default platform is `systrap`, a userspace mechanism
-- `runsc flags` says
`specifies which platform to use: systrap (default), ptrace, kvm.` Probed by
deleting `/dev/kvm` inside the booted node and running the container again: it
still starts, and its `dmesg` still says gVisor.

Nested KVM only comes into play if you pin the `kvm` platform yourself. That
platform opens `/dev/kvm` *inside* the node, which needs
`/sys/module/kvm_intel/parameters/nested` (or `kvm_amd`) to read `Y` on the
machine the test executes on -- on a remote builder, that builder's setting, not
the one on the machine you typed `nix build` on. The recipe's default does not
go down that path.

## API

```
mkNode { ... }        -> NixOS module for a test node
hostGateway           == "10.0.2.2"
slirpHostLoopback     == "slirp4netns:allow_host_loopback=true"
examples.hostServiceFromRunsc { pkgs } -> a runnable test
```

`mkNode` arguments, all optional:

| argument        | default        | meaning |
|-----------------|----------------|---------|
| `runtime`       | `"runsc"`      | The name `--runtime=` takes. |
| `makeDefault`   | `false`        | Also set `engine.runtime`, making `--runtime=` optional. Off by default so each `podman run` states which runtime its assertion is about. |
| `gvisorPackage` | `pkgs.gvisor`  | Override to pin or patch gVisor. |
| `extraPackages` | `[ ]`          | Appended to `environment.systemPackages`. |
| `memorySize`    | `2048`         | `mkDefault`. The sentry is a second userspace kernel inside an already-nested VM; the NixOS test default is tight. |
| `diskSize`      | `4096`         | `mkDefault`. |

The module puts `gvisor` on `PATH` as well, purely so a testScript can run
`runsc --version`; podman invokes it through the absolute store path in
containers.conf.

## Running the worked example

```sh
nix build --impure --expr '
  let pkgs = import <nixpkgs> {}; in
  (import ./lib/nixos-test-gvisor-podman).examples.hostServiceFromRunsc { inherit pkgs; }'
```

One node. A Python HTTP server bound to `127.0.0.1` on the node returns a fixed
token; the container has to fetch it. Five subtests:

1. `runsc` appears in `/etc/containers/containers.conf`, and that file is a
   store symlink -- i.e. it came from the generated definition, not from a
   hand-written `environment.etc` entry that would have failed trap 1.
2. `slirp4netns` is on `PATH`.
3. An empty tar is imported as an image (`tar cv --files-from /dev/null | podman
   import - scratchimg`), with `/nix/store` and `/run/current-system/sw/bin`
   bind-mounted in. No image layer is built, and the container's `wget` is the
   same binary the node has.
4. The container's own `dmesg` contains `gVisor`. This is the subtest worth
   copying: `--runtime=runsc` being *accepted* proves only that podman parsed
   the flag. The sentry announcing itself in the container's kernel log is what
   proves the workload is not on the host kernel.
5. Trap 3 in both directions, as described above.

## Relation to `nixos-test-topology`

[`nixos-test-topology`](../../lib/nixos-test-topology) is the companion recipe
for the *outside* of the VM: it takes IP assignment away from the test framework
so multi-node addresses are the ones you declared, and ships fixtures (a
source-address echo server, a FORWARD-hook packet counter) for proving where
traffic actually went. This recipe is the *inside*: one node, and the path from
a container to the node it runs in.

They compose -- import `topo.nodes.<host>` and `mkNode { }` into the same node --
and the same discipline applies to both. `nixos-test-topology`'s trap 4 is that
a request failing proves nothing about the rule you think blocked it; trap 3
here is the same shape one layer in. Reach for its `forwardCounter` before
concluding that a container's traffic was filtered, and for its `httpEcho`
when the container needs to prove *which* source address the node saw.

## Caveats

- `--network=slirp4netns` on a **root** container is what the example uses,
  because a NixOS testScript runs as root. The NixOS podman module leaves
  `containersConf.settings.network.default_rootless_network_cmd` unset, so
  rootless containers with no `--network=` get whatever podman's own default is
  -- and, per trap 2, that same unset option is why the module does not put
  `slirp4netns` on `PATH` for you.
- `log` is bound to the test driver's logger inside a testScript. Assigning
  command output to it fails the driver's type check with
  ``error[invalid-assignment]: Object of type `str` is not assignable to `AbstractLogger` ``
  -- at build time, before any VM starts.
- The scratch-image trick bind-mounts the whole store into the container. That
  is fine for a test and wrong for anything else -- it hands the container every
  path the node has.
- `hostGateway` is a slirp4netns default, not something the node configuration
  chooses. If you pass slirp4netns your own CIDR, the exported constant no
  longer matches.
