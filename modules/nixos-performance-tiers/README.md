# nixos-performance-tiers

Workload-class **performance** defaults for NixOS: `builder`, `services`,
`workstation`, `hypervisor`. CPU frequency policy, zram/swap behaviour, ZFS
scrub and trim policy, and the handful of mitigations that are genuinely
expensive — each one an explicit, auditable per-host decision rather than
something a workload label silently implies.

This is the deliberate sibling of
[`nixos-hardening-tiers`](nixos-hardening-tiers.md). That recipe owns the
security trade-offs; this one owns the performance ones. They are separate
modules because they are separate decisions, and because they *fight* — most of
this README is about who wins which fight and why.

Everything is off until a host sets `tuning.enable = true`.

## The problem

### 1. Upstream has no performance profile

nixpkgs ships workload profiles in `nixos/modules/profiles/`. As of nixpkgs
`nixos-unstable` (`.version` 26.11) that directory contains:

```
all-hardware  base  bashless  clone-config  demo  docker-container
graphical  hardened  headless  image-based-appliance  installation-device
macos-builder  minimal  nix-builder-vm  perlless  qemu-guest
```

None of them is about performance:

- `nixos/modules/profiles/headless.nix` is *console* policy — it disables
  gettys, sets `panic=1`, drops the GRUB splash. Nothing about CPU, memory or
  storage.
- `nixos/modules/profiles/minimal.nix` is *closure size* — it turns off
  documentation, `command-not-found`, logrotate, udisks2, xdg. Nothing about
  runtime behaviour.
- `nixos/modules/profiles/hardened.nix` is now a **removal stub**: its whole
  body is `lib.mkRemovedOptionModule [ "profiles" "hardened" ]` pointing at the
  26.05 release notes. It went the *other* way and no longer exists.

So there is no upstream answer to "this box is a build machine / a hypervisor /
a laptop, give me sane CPU, swap and ZFS defaults for that". Every host either
inherits a kernel default nobody looked at, or grows a hand-written value in its
own `configuration.nix`. That is what this module replaces.

### 2. Hardening tiers quietly own performance knobs

A hardening profile is not a security-only object. It sets `vm.swappiness`, it
disables SMT, it forces page-table isolation, it turns off the BPF JIT. If you
add a performance module next to it and do not think hard about option
priority, one of two things happens: the two modules **collide** and the host
stops evaluating, or one silently wins and you never find out which.

The whole design of this recipe is: **lose every priority fight on purpose,
except one.**

## Traps

### Trap 1 — it loses every priority fight except `vm.swappiness`

Almost every assignment here is `lib.mkDefault` (priority 1000) or is emitted
only when the corresponding option is non-`null`. That is intentional. If a
host, a disko config, or a hardening tier already said something, this module
must not argue.

`vm.swappiness` is the single exception. It is a **plain assignment**
(priority 100):

```nix
boot.kernel.sysctl."vm.swappiness" = cfg.memory.swappiness;
```

Why: the hardening recipe's `basic` tier pins `vm.swappiness = mkDefault 2`.
Hosts that opted into *more* hardening therefore had their only swap device
made near-inert — the memory policy and the mitigation were written by
different people and never read together. A plain assignment beats `mkDefault`
without reaching for `mkForce`, so the host still gets the last word by writing
its own plain assignment or `mkForce`.

`mkForce` *would* be required for a key the hardening recipe sets unqualified
(e.g. `vm.vfs_cache_pressure`). That fight is not picked here — if you want it,
you have to say `mkForce` yourself and know that you are overruling a security
tier.

### Trap 2 — `mkOverride 900`, because `mkDefault` is a *conflict*

A hardening `medium` tier sets `security.lockKernelModules = mkDefault true`.
A workstation needs it off (v4l2loopback, VirtualBox, waydroid, DKMS, out-of-
tree GPU drivers all `modprobe` after boot).

Writing `mkDefault false` here does **not** mean "prefer false". Two
`mkDefault`s with *different* values at the same priority are a merge
**conflict**, and the host fails to evaluate with
`The option 'security.lockKernelModules' has conflicting definition values`.
Writing `mkForce false` works but makes the value unoverridable — a host that
genuinely wants modules locked would then need `mkOverride 49` or lower, which
nobody discovers.

So: `lib.mkOverride 900 false`. Below `mkDefault` (1000), above nothing else
anybody uses, and still beatable by a plain host assignment (100) or `mkForce`
(50).

```nix
security.lockKernelModules = lib.mkOverride 900 false;
```

### Trap 3 — the assertion reads the *merged* sysctl, not the tier flag

`sched_ext` schedulers are BPF `struct_ops` programs. With
`net.core.bpf_jit_enable = 0` the `scx` unit starts, fails to attach, and burns
through its restart limit. The result is a dead unit and no error anybody
looks at — the scheduler is simply not running and the machine feels the same
as before.

The naive assertion checks the hardening tier's flags (`hardening.basic ||
hardening.advanced`). That is wrong in both directions: it hard-codes another
module's internals, and it punishes a host that deliberately re-enabled the JIT.

This module instead reads the **effective, post-merge value out of the final
config**:

```nix
jitValue = config.boot.kernel.sysctl."net.core.bpf_jit_enable" or true;
jitEnabled = !(builtins.elem jitValue [ false 0 "0" ]);
```

Note the three-value membership test. `boot.kernel.sysctl`'s value type is a
custom `mkOptionType` whose check is `isBool x || isString x || isInt x || x ==
null` (`nixos/modules/config/sysctl.nix`, the `sysctlOption` let-binding at the
top of the file), so "off" legitimately arrives as `false`, `0`, or `"0"`
depending on who wrote it, and `x == false` would miss two of the three. The
`or true` covers "nobody set it", which is the kernel default (JIT on).

While you are in that file, note `merge = lib.mergeOneOption`: two definitions
of the *same* sysctl key at the *same* priority are a hard error, not a
last-one-wins. That is why every sysctl below is either `mkDefault` or a
deliberate single plain assignment.

This is a cross-module read: it works regardless of *which* module turned the
JIT off, or whether that module exists at all.

### Trap 4 — zram sizing INVERTS on whether disk swap exists

The instinct is "zram is a cache, keep it small". That is backwards when zram
is the *only* swap device:

| | `swapDevices != []` | zram is the only swap |
| --- | --- | --- |
| `memory.zram.memoryPercent` | 25 | **50** |
| `memory.swappiness` | 150 | **180** |

- **memoryPercent.** With a disk backstop, 25% is plenty — anything zram
  refuses spills to disk. With *no* backstop, shrinking zram does not save
  memory, it lowers the ceiling before the OOM killer runs. Cutting it to 25%
  raises OOM risk on exactly the hosts that already OOM under build load.
- **swappiness.** 180 (`> 100`, legal since Linux 5.8's `MEMCG` swappiness
  rework) says "prefer swapping anonymous pages over evicting page cache",
  which is correct when swapping means *compressing into RAM*. The moment any
  disk swap exists, that same preference sends writes to NAND, so it is capped
  at 150: still swap-forward, but no longer pretending the device is free.

Detection is `config.swapDevices != [ ]`. `zramSwap` does **not** register
itself in `swapDevices`, so this check reads exactly "is there a backstop" and
does not see itself.

### Trap 5 — `vm.page-cluster = 0`, always

The kernel default `vm.page-cluster = 3` faults in 2³ = 8 pages per swap-in to
amortise disk seek cost. A zram device has no seek cost, so the readahead is
pure decompression work on pages nobody asked for. `0` reads exactly the
faulting page. This is the cheapest, least controversial win on any zram host
and there is no workload where the default is better.

### Trap 6 — ZFS ARC has no safe default, so the default is `null`

`memory.arcMaxBytes` is `nullOr int`, default `null`, and that is not laziness.
Uncapped ARC takes roughly 50% of physical memory and competes directly with
databases, passthrough VM memory, inference runtimes and zram. But a *guessed*
cap is worse than none: set it too low on a fileserver and you destroy read
performance, set it too high on a host with 100 GB of VM allocations and you
OOM production. The number has to come from the host's actual installed RAM and
actual workload, so the module refuses to invent one.

Delivery is `boot.extraModprobeConfig`, **not** `boot.kernelParams`:

```nix
boot.extraModprobeConfig = "options zfs zfs_arc_max=${toString cfg.memory.arcMaxBytes}\n";
```

`zfs` is a loadable module here, so the `zfs.zfs_arc_max=` kernel-cmdline form
is not a reliable delivery path. `extraModprobeConfig` is `types.lines`, so it
concatenates cleanly with whatever else writes modprobe options (for instance
the hardening recipe's `install <module> /bin/true` stub).

### Trap 7 — fstrim is *set* to false, never asserted on

On a ZFS root, `fstrim` is the wrong tool: ZFS exposes no `FITRIM` ioctl, so
the timer is at best a no-op and at worst hides the fact that nobody enabled
`services.zfs.trim`, which is the mechanism that actually discards.

The tempting implementation is an assertion — "you have ZFS, turn fstrim off".
It fires on every ZFS host immediately, because upstream's default is **true**,
and unusually so. `nixos/modules/services/misc/fstrim.nix` writes:

```nix
enable = (
  lib.mkEnableOption "periodic SSD TRIM of mounted partitions in background"
  // {
    default = true;
  }
);
```

That is `mkEnableOption` with the default flipped — so `services.fstrim.enable`
is on for every host in the fleet, imported nixos-hardware SSD profile or not,
and an assertion would break every ZFS host on the first deploy. (nixos-
hardware's `common/pc/ssd` is a red herring: fstrim is on with or without it.)

So this module *sets* it, at `mkDefault false`, so hosts that already opt out
by hand — plain `false` or `mkForce false` — keep working unchanged and nothing
collides.

The same reasoning applies to `services.zfs.autoScrub.interval`: hosts whose
disko config already states an interval as a plain assignment would **collide**
with a plain assignment here, so it is `mkDefault`.

### Trap 8 — one option emits no configuration at all, on purpose

`storage.noSnapshotPaths` produces nothing. Not a warning, not a systemd unit —
nothing.

ZFS dataset properties are **live state**, not declarative config. `disko`'s
`options` apply at pool-create time and disko never re-runs on an installed
host, so there is no declarative path from "this dataset should not be
snapshotted" to the running system. The real change is two imperative
commands:

```sh
zfs set com.sun:auto-snapshot=false <pool>/<dataset>
zfs destroy <pool>/<dataset>@zfs-auto-snap_...     # the ones already taken
```

The option exists so the intent is recorded and reviewable next to everything
else, and so the next person can diff intent against `zfs get -r
com.sun:auto-snapshot`. Declaring a knob that lies about being declarative is
worse than declaring one that says so in its own description — which this one
does, in capitals.

Why it matters at all: an auto-snapshot rotation that keeps ~4 weeks will pin
every store path the weekly `nix-collect-garbage` deleted, so `/nix` grows
monotonically until someone notices. Same story for container image layers.

### Trap 9 — `role` sets DEFAULTS ONLY

The obvious design is to derive everything from `role`. Do not. Welding `nosmt`,
PTI, the L1D flush, `io_uring` and `sched_ext` to a workload label repeats, one
level up, exactly the mistake that made the hardening tiers confusing: the label
has nothing to say about those knobs.

So the five genuinely expensive trade-offs are **tri-state** under
`tuning.tradeoffs`:

- `null` — emit nothing, inherit whatever the hardening tier decided.
- `true` / `false` — an explicit, auditable, per-host decision.

`null` is not the same as "override to the same value". Emitting nothing is
what lets a hardening tier keep ownership; emitting `false` takes ownership
away silently.

### Trap 10 — `slub_debug` is a debug facility, not hardening

`cpu.slabDebug` adds `slub_debug=FZP`. It is frequently mistaken for a KSPP
hardening recommendation. It is not: it disables slab merging *and* forces
every affected cache off the SLUB fastpath with red-zoning and per-object
consistency checks. Never leave it on permanently on a host that serves traffic
or builds packages.

`cpu.slabNoMerge` (`slab_nomerge`, default **on**) is the part you actually
want: it buys the cache-separation property without the debug slowpath.

`page_poison=1` is deliberately **absent**. It has been a no-op since Linux
5.11 *and* it takes precedence over `init_on_alloc`, silently suppressing
nixpkgs' own `INIT_ON_ALLOC_DEFAULT_ON`.

## Usage

```nix
{
  imports = [
    ./nixos-hardening-tiers      # the sibling recipe (optional)
    ./nixos-performance-tiers
  ];

  tuning = {
    enable = true;
    role = "builder";
    tradeoffs = {
      smt = true;               # nix.settings.cores was sized SMT-on
      pti = false;              # AMD Zen, no untrusted local code
    };
    memory.arcMaxBytes = 68719476736;   # 64 GiB, from THIS host's RAM
    hardeningTier.apply = true;         # drive hardening.{basic,medium}
  };
}
```

A hypervisor running untrusted guests:

```nix
tuning = {
  enable = true;
  role = "hypervisor";
  tradeoffs.l1dFlush = "always";
  memory = {
    arcMaxBytes = 34359738368;   # 32 GiB
    zram.memoryPercent = 25;     # this host has disk swap
  };
};
```

A workstation:

```nix
tuning = {
  enable = true;
  role = "workstation";          # => hardeningTier.medium defaults off,
                                 #    unlockKernelModules defaults on
  tradeoffs.schedExt = "scx_lavd";   # needs the BPF JIT — see Trap 3
};
```

### Wiring the hardening tier

`tuning.hardeningTier.apply` defaults to **false** so this recipe never assumes
another module's option path exists. Two ways to use it:

- Set `apply = true` if you also import `nixos-hardening-tiers`; this module
  then sets `hardening.basic` / `hardening.medium` with `mkDefault`.
- Leave it `false` and forward the computed values yourself if your hardening
  options live elsewhere:

  ```nix
  myNamespace.harden.basic  = lib.mkDefault config.tuning.hardeningTier.basic;
  myNamespace.harden.medium = lib.mkDefault config.tuning.hardeningTier.medium;
  ```

  Keep the `mkDefault`. If your own adapter forwards those with a *plain*
  assignment, this module's `mkDefault` would be silently discarded.

## Options

| Option | Default | Effect |
| --- | --- | --- |
| `tuning.enable` | `false` | Nothing applies until this is on. |
| `tuning.role` | `"services"` | `builder` / `services` / `workstation` / `hypervisor`. Defaults only. |
| `tuning.tradeoffs.smt` | `null` | `security.allowSimultaneousMultithreading`, plain assignment when non-null. |
| `tuning.tradeoffs.pti` | `null` | `security.forcePageTableIsolation`. |
| `tuning.tradeoffs.l1dFlush` | `null` | `security.virtualisation.flushL1DataCache` (`never`/`cond`/`always`). |
| `tuning.tradeoffs.ioUring` | `null` | `false` ⇒ `kernel.io_uring_disabled = 2`. |
| `tuning.tradeoffs.schedExt` | `null` | `services.scx.scheduler`. Asserted against the effective BPF JIT sysctl. |
| `tuning.cpu.governor` | `"performance"` if `role == "builder"`, else `null` | `powerManagement.cpuFreqGovernor`, `mkDefault`. |
| `tuning.cpu.slabNoMerge` | `true` | `slab_nomerge` kernel param. |
| `tuning.cpu.slabDebug` | `false` | `slub_debug=FZP`. DEBUG ONLY. |
| `tuning.memory.zram.enable` | `true` | `zramSwap.enable`, `mkDefault`. |
| `tuning.memory.zram.memoryPercent` | `25` with disk swap, else `50` | See Trap 4. |
| `tuning.memory.swappiness` | `150` with disk swap, else `180` | Plain assignment. See Trap 1. |
| `tuning.memory.pageCluster` | `0` | `vm.page-cluster`. See Trap 5. |
| `tuning.memory.watermarkBoostFactor` | `0` | `vm.watermark_boost_factor`. |
| `tuning.memory.watermarkScaleFactor` | `125` | `vm.watermark_scale_factor`. |
| `tuning.memory.arcMaxBytes` | `null` | ZFS ARC cap in bytes, via `extraModprobeConfig`. See Trap 6. |
| `tuning.storage.manageZfs` | `true` | Apply ZFS policy on hosts with a `zfs` filesystem. |
| `tuning.storage.scrubInterval` | `"monthly"` | `services.zfs.autoScrub.interval`, `mkDefault`. |
| `tuning.storage.disableFstrim` | `true` | `services.fstrim.enable = mkDefault false`. See Trap 7. |
| `tuning.storage.noSnapshotPaths` | `[ "/nix" "/var/lib/docker" ]` | **Emits nothing.** See Trap 8. |
| `tuning.hardeningTier.basic` | `true` | Computed intent for the cheap hardening tier. |
| `tuning.hardeningTier.medium` | `role != "workstation"` | Computed intent for the invasive tier. |
| `tuning.hardeningTier.apply` | `false` | Forward the two above into `hardening.*`. |
| `tuning.hardeningTier.unlockKernelModules` | `role == "workstation"` | `security.lockKernelModules = mkOverride 900 false`. |

## Caveats

- **ZFS detection is `fileSystems`-based.** `storage.*` only applies when some
  entry in `config.fileSystems` has `fsType = "zfs"`. A host with ZFS pools that
  are not mounted through `fileSystems` (an imported data pool, say) will not
  trigger the policy — set `services.zfs.*` directly there.
- **`zramSwap.enable` is `mkDefault`.** If another module in your tree already
  enables zram unconditionally, this module states intent without colliding,
  but you should check nobody has hidden a `SuccessExitStatus = [ 1 ]` on
  `systemd-zram-setup@` — that turns a *failed* zram setup into a silent
  success and is a common copy-paste.
- **`memory.swappiness > 100` requires Linux ≥ 5.8.** On older kernels the
  sysctl clamps at 100 and the zram-forward behaviour is not available.
- **`tradeoffs.pti = false` is a real security decision**, not a tuning knob.
  It is here because the alternative — having it implied by `role = "builder"` —
  is worse, not because it is cheap.
- **Changing `cpu.governor` on a laptop costs battery.** The `null` default is
  correct for attended machines: `schedutil` and `amd-pstate-EPP` already reach
  maximum clocks under sustained load, so pinning `performance` buys latency at
  idle, not throughput under load.
