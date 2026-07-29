# mlx-metal-gpu-overlay

Build [MLX](https://github.com/ml-explore/mlx) with **Metal GPU** support under
Nix on Apple Silicon (`aarch64-darwin`).

## Problem

nixpkgs ships MLX **CPU-only**. Enabling Metal is not just a build flag: MLX
compiles its Metal shaders by shelling out to `xcrun -sdk macosx metal` /
`metallib`. `xcrun` is a thin locator that resolves the active developer
toolchain — and it is **invisible inside the Nix build sandbox**. So a naive
"flip `MLX_BUILD_METAL` to ON" build fails the moment CMake tries to invoke the
shader compiler.

## Key insight / traps

1. **`xcrun` doesn't work in the sandbox — call the compiler directly.** The
   real `metal`/`metallib` binaries live inside Apple's *Metal toolchain
   cryptex*, mounted at `/var/run/com.apple.security.cryptexd/mnt/` under a
   directory whose name carries a version suffix
   (`com.apple.MobileAsset.MetalToolchain-<version>`). That suffix changes with
   OS/Xcode updates, so the overlay **discovers the path at eval time**
   (`builtins.readDir`) instead of hardcoding it, and rewrites MLX's build
   scripts to call those binaries directly, passing `-isysroot <MacOSX.sdk>`.

2. **`__noChroot = true` is mandatory.** The Metal compiler needs the real
   toolchain and SDK present on disk at build time; they cannot be brought into
   a sealed sandbox. This requires the daemon to allow it —
   `sandbox = relaxed` (or `false`) in `nix.conf`. With full sandboxing enforced
   the flag is ignored and the build fails.

3. **Graceful CPU fallback.** If the toolchain cryptex is not mounted,
   `metalToolchainDir` evaluates to `null`, the Metal patches are skipped, and
   MLX builds CPU-only. No hard failure.

4. **Several `xcrun` shellouts, not one.** The version probe in `CMakeLists.txt`
   is made non-fatal (it otherwise aborts configure), a deployment-target guard
   is removed, and both `kernels/CMakeLists.txt` and `make_compiled_preamble.sh`
   have their `xcrun ... metal` invocations rewritten. Missing any one of them
   reintroduces the failure.

5. **`env -u MACOSX_DEPLOYMENT_TARGET`.** A stray `MACOSX_DEPLOYMENT_TARGET` from
   the build environment breaks the direct `metal` invocation, so it is unset
   just for that command.

6. **The CPU JIT hardcodes `g++`.** Separately from the Metal path,
   `mlx/backend/cpu/jit_compiler.cpp` shells out to a bare `g++`, which isn't
   on the sandbox `PATH`. It is rewritten to the Nix stdenv `c++`, so the CPU
   path builds hermetically too — this patch applies whether or not the Metal
   toolchain was found.

7. **Pre-fetched FetchContent sources.** MLX's CMake uses `FetchContent` to pull
   `metal-cpp` and `nanobind` from the network — which the sandbox blocks. Both
   are pre-fetched into the store and passed via
   `FETCHCONTENT_SOURCE_DIR_*`.

## Usage

Add the overlay to an `aarch64-darwin` configuration and consume
`python3Packages.mlx`:

```nix
{
  nixpkgs.overlays = [ (import ./overlays/mlx-metal-gpu-overlay) ];
}
```

Then, e.g. `python3.withPackages (ps: [ ps.mlx ])`.

### Requirements

- **Apple Silicon** running macOS with **Xcode** installed (provides the MacOSX
  SDK at the path in `sdk`).
- The **Metal toolchain** component present (mounts the cryptex the overlay
  discovers). Without it you get a CPU-only build.
- **Relaxed sandbox** so `__noChroot` is honored:

  ```
  # /etc/nix/nix.conf  (or nix.settings on nix-darwin)
  sandbox = relaxed
  ```

### Pinning

The MLX version + `src` hash, and the `metal-cpp` / `nanobind` revisions and
hashes, are pinned inline in `default.nix`. Bump them to the MLX release you
want; update the `hash` values to match.

## Caveats

- The `sdk` path and the cryptex mount path are macOS/Xcode conventions; if
  Apple relocates them in a future release these constants need updating.
- `__noChroot` makes the build **impure** — its output depends on the toolchain
  present on the build host. That is inherent to how Apple ships the Metal
  compiler; there is no fully-hermetic path today.
- The CMake `--replace-fail` / `sed` anchors are tied to MLX's source layout at
  the pinned version. A major MLX refactor may move them.
