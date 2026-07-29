# nixpkgs-instance-matrix

Instantiate the nixpkgs matrix — **stable/unstable × CPU/CUDA/aarch64** — exactly
once, up front, then let every host reuse the pre-built sets through a cheap
selector.

## The problem

`import nixpkgs { overlays = ...; config = ...; }` is not free. Every import
re-runs your overlays and re-evaluates config. If each host in a flake imports
nixpkgs itself — a common pattern when hosts differ by system or need CUDA — you
pay that evaluation cost once per host, and you get several *distinct* nixpkgs
instances floating around (which also defeats store-path sharing and slows
evaluation further).

Instead: build the handful of variants you actually use in **one place**, then
hand each host a selector that picks the right pre-built set.

```nix
pkgsLib = import ./lib/nixpkgs-instance-matrix {
  inherit (inputs) nixpkgs nixpkgs-unstable;
  defaultConfig  = { allowUnfree = true; };
  cudaConfig     = { cudaSupport = true; cudaCapabilities = [ "8.9" ]; };
  baseOverlays   = [ (import ./overlays) ];
  stableOverlays = [ (import ./overlays/from-unstable.nix { unstable = ...; }) ];
};

# per host, in specialArgs / module args:
pkgs = pkgsLib.pkgsFor { inherit system; extraCfg = { cudaSupport = true; }; };
```

`pkgsFor` and `unstableFor` are pure selectors over already-instantiated sets —
calling them is essentially free.

## The key insight: "unstable follows stable"

The `nixpkgs-unstable` argument defaults to `nixpkgs`. In many flakes the
unstable input `follows` the stable input in `flake.lock`, so they resolve to
the **same pin**. When that is the case, "unstable" is *not a different channel*.
It is the same source instantiated with only your `baseOverlays` — deliberately
**without** the extra `stableOverlays` that the fully-built stable sets carry.

Why keep a set like that around? It is an **escape hatch**. When your stable
overlays would hand a module a patched or backported variant of a package that
it specifically does *not* want, the module can reach into the lightly-overlaid
`unstable*` set and grab the plain one. If instead you want unstable to track a
genuinely newer release, point the `nixpkgs-unstable` argument at a different
channel and the whole mechanism still works — you then get a real second
channel plus the same escape-hatch ergonomics.

## Two traps

1. **Overlay ordering / who wins on collisions.** In `mkPkgs` the stable set's
   overlay list is `stableOverlays ++ baseOverlays`. `baseOverlays` come **last**,
   so they apply last and **win** on any attribute-name collision with
   `stableOverlays`. That is intentional: fleet-wide overrides stay
   authoritative even when a "pull this from unstable" overlay names the same
   package. If you flip the order, the extra overlays win instead — rarely what
   you want.

2. **CUDA capabilities are build-cost and correctness-sensitive.** List only the
   compute capabilities of GPUs you actually build for — each extra capability
   multiplies CUDA build time. Some capability + package combinations
   miscompile (a very new architecture capability can, for example, break opencv
   under nvcc with a signal 11). Pin `cudaCapabilities` deliberately and test
   the packages you care about, rather than throwing in every capability
   "to be safe."

## Options

All arguments have defaults; override what you need.

| Argument           | Default              | Purpose |
|--------------------|----------------------|---------|
| `nixpkgs`          | *(required)*         | Stable channel input. |
| `nixpkgs-unstable` | `nixpkgs`            | Unstable channel; defaults to the same pin (the escape-hatch case above). |
| `defaultSystem`    | `"x86_64-linux"`     | Primary build system. |
| `aarch64System`    | `"aarch64-linux"`    | The aarch64 target the selectors switch on. |
| `defaultConfig`    | `{ allowUnfree = true; }` | nixpkgs `config` for every variant. |
| `cudaConfig`       | `{ cudaSupport = true; cudaCapabilities = [ "8.9" ]; cudaEnableForwardCompat = true; }` | Merged over `defaultConfig` for CUDA variants. |
| `baseOverlays`     | `[ ]`                | Fleet-wide overlays; applied **last**, win on collision. |
| `stableOverlays`   | `[ ]`                | Extra overlays for the stable sets only; applied ahead of `baseOverlays`. |
| `cudaOverlays`     | `[ ]`                | Extra overlays for the unstable CUDA variant only. |

## What it returns

```
mkUnstable        mkUnstableCuda        # variant constructors (system -> pkgs)
unstableDefault   unstableCuda   unstableAarch64
unstableFor { extraCfg ? {}, system ? defaultSystem }   # selector

mkPkgs                                   # stable constructor ({ system, cuda ? false } -> pkgs)
pkgsDefault       pkgsCuda       pkgsAarch64
pkgsFor { extraCfg ? {}, system ? defaultSystem }        # selector
```

The selectors branch on `extraCfg.cudaSupport` first, then on
`system == aarch64System`, else the default set — so a host declaring
`{ cudaSupport = true; }` in its `extraCfg` transparently gets the CUDA set
regardless of anything else.

## Caveats

- The pre-built sets are only worth it when several hosts share the same few
  variants. If every host needs a bespoke config, per-host instantiation is
  unavoidable and this pattern buys you nothing.
- `cudaOverlays` here applies to the **unstable** CUDA variant. If you need
  CUDA-only overlays on the *stable* CUDA set as well, extend `mkPkgs` to take a
  `cuda`-conditional overlay list — the structure makes that a one-line change.
- Adding a new variant (a second aarch64 config, a ROCm set, …) means adding one
  `mk*` call and one selector branch. Keep the number of variants small; the
  whole point is that the matrix is finite.
