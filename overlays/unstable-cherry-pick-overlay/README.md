# unstable-cherry-pick-overlay

Cherry-pick a few fast-moving packages from **nixpkgs-unstable** onto an
otherwise **stable** nixpkgs, using a plain overlay — and survive the small
build fixes those packages recurrently need to compile in the Nix sandbox.

## The problem

You want your system pinned to a stable nixpkgs channel for reproducibility and
cache hits, but a handful of packages (editors, AI/CLI tools, dev utilities)
move fast enough that the stable version is uselessly old. You don't want to
flip the *whole* system to unstable just for them.

An overlay solves the pinning half in one line:

```nix
inherit (unstable) atuin neovim;
```

The part that bites you is the *other* half: fast-moving packages regularly
fail to build under the Nix sandbox, and you have to patch around it right here
in the overlay.

## The traps (why this file exists)

The Nix build sandbox has **no network**, **no `/dev/ptmx`**, and **tight fd
limits**. Two failure shapes recur:

1. **Sandbox-incompatible tests.** A test assumes network access, a pty, or
   loose fd limits, so it fails in the sandbox even though the package itself is
   fine. This is not a real regression — disable the offending tests, don't
   pin backwards.
   - Surgical: `disabledTests = old.disabledTests ++ [ "test_foo" ]` when only a
     few tests are the problem (the `aider-chat` example).
   - Wholesale: `doCheck = false` when the whole suite is unsafe — e.g. a test
     suite that aborts the build on `OpenptyFailed` because there's no
     `/dev/ptmx` (the `ghostty` example).

2. **A pinned build backend that lags.** A Python package may pin its PEP-517
   build backend (`uv_build`, `setuptools`, `hatchling`, …) to a narrow version
   range that the unstable interpreter set no longer provides — so it fails to
   **build**, not test. Relax the pin and feed the backend in from unstable (the
   `marimo` example):
   - filter out any nixpkgs patch that re-pins the backend,
   - `substituteInPlace pyproject.toml` to widen the version bound (use
     `--replace-quiet` so it's a harmless no-op once upstream relaxes it),
   - add the backend (and any newly-required deps) from `unstable.python3Packages`.

Keeping these fixes *in the overlay* means the day a package needs the
workaround, you add three lines; the day upstream fixes it, you delete them —
without ever leaving your stable base.

## Usage

Add an unstable nixpkgs input alongside your stable one:

```nix
inputs.nixpkgs.url          = "github:NixOS/nixpkgs/nixos-25.05";
inputs.nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
```

Instantiate the unstable set for the **same** `system`/`config` as your base,
then apply the overlay:

```nix
let
  unstable = import inputs.nixpkgs-unstable {
    inherit system;
    config.allowUnfree = true;   # match your base config
  };
in
import inputs.nixpkgs {
  inherit system;
  overlays = [
    (import ./overlays/unstable-cherry-pick-overlay { inherit unstable; })
  ];
}
```

Now `pkgs.neovim`, `pkgs.ghostty`, etc. resolve to the unstable builds while the
rest of your system stays on the stable channel.

## Arguments

| Arg        | Required | What it is |
|------------|----------|------------|
| `unstable` | yes      | A **fully-instantiated** nixpkgs-unstable package set (`import nixpkgs-unstable { ... }`), not the raw flake input. Instantiate it for the same `system`/`config` as your base. |
| `zig`      | no       | Optional example of pulling a package from a *third* source — an external flake input exposing `packages.<system>.*`. Omit it (and the `zig` attr) if you don't need it. |

## Caveats

- **Cache hits.** Cherry-picking from unstable means those packages build
  against the unstable channel; expect them to (re)build from source unless the
  unstable binary cache covers your `system`. Overriding attrs (`doCheck`,
  patches) also perturbs the derivation hash, guaranteeing a local rebuild — fine
  for a few tools, painful if you do it to something huge like a compiler
  toolchain. Prefer leaving cache-hitting packages untouched.
- **Config drift.** If your base sets `config.allowUnfree`, `cudaSupport`, etc.,
  set the same on the instantiated `unstable` set or the cherry-picked packages
  may evaluate differently (or refuse to evaluate).
- **Disable the narrowest thing that works.** Reach for `disabledTests` before
  `doCheck = false`; you keep the rest of the suite as a real signal.
- **Interpreter skew is the usual root cause.** Build-backend and dependency
  breakage almost always traces back to unstable's Python version having moved
  ahead of what the package pinned. Relaxing the pin is the fix; bumping the
  package version sometimes removes the need entirely.
