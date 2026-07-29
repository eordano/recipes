# aarch64-native-webassets-overlay

A nixpkgs overlay that sources arch-agnostic web packages (static HTML/JS/CSS
bundles) from a freshly imported **native x86_64** pkgs on an aarch64 builder,
so the JS toolchain is never run under emulation.

## The problem

You are building for `aarch64-linux` on an aarch64 machine (or cross/emulated
via `qemu-user` / binfmt). A web package such as `element-web` or `jitsi-meet`
fails to build with something like:

```
uncaught target signal 4 (Illegal instruction) - core dumped
```

The build runs `webpack`, which spins up Node's **V8 JIT**. Under `qemu-user`
emulation the JIT generates host-native machine code that the emulator cannot
execute, and the build dies with **SIGILL**. This is not a bug in the package —
it is the JIT tripping over the emulator.

## The insight

The *output* of these packages is **platform-independent**: minified JS, CSS,
HTML, images. Nothing arch-specific ends up in the store path. So the
x86_64-built derivation is a perfectly valid substitute on aarch64.

Instead of emulating webpack, import a fresh `x86_64-linux` pkgs from the same
nixpkgs source (`prev.path`) and take the package from there. On an x86_64
builder (or via a native/remote x86_64 build) the toolchain runs on real
hardware — the emulator never touches the JS build at all.

## Usage

`default.nix` is a **function returning an overlay**. Call it with the list of
attribute names you want sourced natively, then add the result to your
`overlays` / `nixpkgs.overlays`:

```nix
nixpkgs.overlays = [
  # defaults to [ "element-web" ]
  (import ./aarch64-native-webassets-overlay { })

  # or choose your own:
  (import ./aarch64-native-webassets-overlay {
    packages = [ "element-web" "jitsi-meet" ];
  })
];
```

### Option

| name       | default             | meaning |
|------------|---------------------|---------|
| `packages` | `[ "element-web" ]` | Attribute names in pkgs to replace with their natively-built x86_64 equivalents on aarch64-linux. |

The overlay is a no-op on any non-`aarch64-linux` system, so it is safe to apply
unconditionally in a shared config.

## Traps and caveats

- **Apply it first.** Add this overlay *before* any overlay that patches or
  depends on the listed packages. As soon as something references the emulated
  `element-web`, that build is pinned and the substitution can no longer take
  effect.

- **Only for arch-agnostic outputs.** Every name you pass must produce output
  with **no native binaries** — pure static web assets. If you list a package
  whose closure contains compiled ELF, you will ship x86_64 binaries onto an
  aarch64 host and they will not run.

- **You still need an x86_64 build path.** This overlay moves the build to
  x86_64; it does not make it appear from nowhere. Building on aarch64 alone,
  you need an x86_64 builder available (a remote builder, or an x86_64 host in
  your `nix.buildMachines`). The point is to avoid emulating the JS toolchain,
  not to avoid building it.

- **Same nixpkgs revision.** Using `prev.path` (not a separately pinned
  nixpkgs) guarantees the native pkgs is the exact revision backing your current
  pkgs, and `config` is carried across so `allowUnfree` /
  `permittedInsecurePackages` / etc. still apply to the native instantiation.

- **The proper fix is a patched qemu.** If you want the emulated build to work
  (e.g. no x86_64 builder available), the underlying cure is a `qemu-user`
  binfmt that handles the JIT correctly. This overlay is the pragmatic
  workaround when the output is arch-independent anyway.
