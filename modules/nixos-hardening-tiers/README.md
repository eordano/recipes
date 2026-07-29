# nixos-hardening-tiers

Opt-in, **stackable** NixOS kernel/network hardening tiers in one module.
A host picks how much it wants (`basic` / `medium` / `advanced`, plus
independent `antivirus` and `malloc` toggles); everything defaults **off**, so
importing the module changes nothing until a host asks for it.

The value here is the module *shape*, not the specific sysctls. Copy the
structure and swap in your own knobs.

## The problem

You want a menu of hardening levels that hosts can dial up individually — a
laptop takes everything, a build box takes only the cheap stuff — from a single
module. Two things bite you when you build this naively, and both fail
*silently* (the module still evaluates, still passes review):

### Trap 1 — the config MUST be `mkMerge`, never `//`

The module body is an always-on block plus one `mkIf` per tier. It is tempting
to combine them with `//`:

```nix
config = alwaysBlock // (mkIf cfg.basic { ... }) // (mkIf cfg.advanced { ... });
```

In Nix `//` is right-biased attrset update: `a // b // c` evaluates to `c` with
only top-level keys merged. So that line **throws away every block but the
last** — the whole module quietly becomes a near-no-op. It still type-checks, it
still builds, and nobody notices until an audit finds none of the sysctls
actually applied. Use `mkMerge`, which is the NixOS module system's real merge:

```nix
config = mkMerge [
  { /* always-on */ }
  (mkIf cfg.basic    { ... })
  (mkIf cfg.medium   { ... })
  (mkIf cfg.advanced { ... })
];
```

### Trap 2 — shared keys across tiers must be deduped

Tiers stack: a host can run `basic` **and** `advanced` at once. If two tiers
both define the same sysctl, the NixOS module system sees two definitions of
one option and you get a collision (or a fragile priority tie-break). Two
patterns in this module fix that:

- **Guard the duplicate.** Five net/vm keys are wanted by both `basic` and
  `advanced`. They live in `basic`; the `advanced` block only sets them
  `lib.mkIf (!cfg.basic)`, i.e. "only when `basic` isn't already providing
  them." One owner, no collision.

- **Hoist to the always-block as a tri-state.** `kernel.kptr_restrict` would
  otherwise be set once per tier with different values. Instead it lives once
  in the always-on block, `mkIf (cfg.basic || cfg.medium || cfg.advanced)`, and
  computes its value (`if cfg.advanced then 2 else if cfg.medium then 1 else 2`)
  from whichever tiers are on. Defined exactly once, regardless of the combo.

### The always-on block owns non-optional mitigations

Anything that no host should ever be able to turn off goes in the un-guarded
first block, not inside a tier. In this module that is a blacklisted kernel
module (an `install ... /bin/true` modprobe stub also defeats explicit
`modprobe`). Because it is not wrapped in any `mkIf cfg.<tier>`, every importing
host gets it unconditionally — the right home for a CVE mitigation you can't let
a host opt out of.

## Usage

Import the module and enable tiers per host:

```nix
{
  imports = [ ./nixos-hardening-tiers ];

  # A workstation: take everything.
  hardening.basic = true;
  hardening.medium = true;
  hardening.advanced = true;
  hardening.malloc = true;
}
```

```nix
{
  imports = [ ./nixos-hardening-tiers ];

  # A GPU box: strong tiers, but keep runtime module loading so the
  # out-of-tree driver still loads.
  hardening.medium = true;
  hardening.allowKernelModuleLoading = true;
}
```

### Options

| Option | Default | Effect |
| --- | --- | --- |
| `hardening.basic` | `false` | Basic kernel/network sysctls; blacklists legacy fs/net modules; disables unprivileged user namespaces. |
| `hardening.medium` | `false` | Kernel image protection, module locking, ptrace/bpf/dmesg restrictions, TCP SYN-flood hardening, KASLR/kstack randomization. |
| `hardening.advanced` | `false` | Disables SMT, forces PTI + L1D flush, enables AppArmor, `init_on_alloc/free`. Higher performance cost. |
| `hardening.malloc` | `false` | Hardened memory allocator (scudo) with zeroed allocations. |
| `hardening.antivirus` | `false` | ClamAV daemon + updater. |
| `hardening.allowKernelModuleLoading` | `false` | Keep runtime module loading unlocked under `medium` (for GPU drivers / DKMS). |

## Caveats

- **`advanced` has a real performance cost.** Disabling SMT and forcing page
  table isolation / L1D flushing is a meaningful hit on some workloads. Measure
  before enabling it fleet-wide.
- **`medium` locks kernel modules** (`security.lockKernelModules`). Any host
  that loads modules after boot — proprietary GPU drivers, DKMS, some
  virtualization stacks — must set `hardening.allowKernelModuleLoading = true`
  or it will break.
- **The sysctl values are examples.** They are a reasonable starting point, not
  gospel. Treat the tier contents as a template and adjust to your threat model;
  the reusable part is the `mkMerge` + dedup structure.
- **Adding a key to two tiers reintroduces trap 2.** If you extend a tier, check
  whether another tier already sets the same option, and dedup it (guard or
  hoist) the same way the existing shared keys are handled.
