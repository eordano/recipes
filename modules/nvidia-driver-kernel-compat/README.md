# nvidia-driver-kernel-compat

Pin an exact NVIDIA driver version **and** carry the kernel build patches that
version needs, so a bleeding-edge kernel (6.18 / 6.19 / newer) doesn't silently
break the out-of-tree module build — plus sane defaults for open kernel modules
and PRIME offload.

## The problem

Two things routinely break NVIDIA on a fast-moving NixOS system:

1. **The driver floats.** `hardware.nvidia.package = ...nvidiaPackages.latest`
   (or `production`/`beta`) moves whenever you bump `nixpkgs`. A channel bump
   you did for something unrelated can land you on a driver release that
   regresses *your* workload — a hung GPU/VFIO handoff, a broken passthrough
   float, a new modeset quirk. The driver changed, but nothing in your diff says
   so.

2. **New kernels fail to *compile* the modules.** The NVIDIA kernel modules are
   built out-of-tree against your running kernel. Recent kernels break that
   build before nixpkgs' bundled patch set catches up:
   - **kernel 6.18** rearranged the varargs plumbing, so the module's
     `nv-linux.h` must `#include <linux/stdarg.h>` explicitly. Without it the
     build errors out — and takes your whole `nixos-rebuild` with it.
   - **kernel 6.19** needs a further source fixup, packaged by CachyOS ahead of
     upstream.

## The insight

Make the driver an **explicit, pinned choice**, and attach each kernel fixup to
the exact driver version that needs it.

- `driverVersion = "575"` (etc.) selects a fully pinned release — version +
  every hash — via `nvidiaPackages.mkDriver`. A `nixpkgs` bump can no longer
  move you off it. `"latest"` stays available as an explicit escape hatch.
- Each pinned entry carries its own `patchesOpen` list, so the driver that
  builds against kernel 6.18 gets the stdarg patch, the one against 6.19 gets
  both. The compat fix travels *with* the driver, not as a global hack you have
  to remember to remove later.

The kernel patches live next to the module: `nvidia-kernel-6.18-stdarg.patch`
(a two-line include, bundled here) and the 6.19 patch (fetched reproducibly from
CachyOS packaging by pinned revision + hash).

## Open vs proprietary kernel modules

`open` defaults to **true**:

- **Required** on Blackwell (RTX 50xx) and newer.
- **Recommended** on Turing+ (RTX 20xx / GTX 16xx and newer).
- Set `open = false` **only** for pre-Turing GPUs (legacy proprietary module).

Note: the bundled patches target the **open** module source tree (`patchesOpen`).
If you switch to the proprietary module you'll need the equivalent `patches`
argument — the source layout differs, so the open-module patches won't apply
unchanged.

## Usage

```nix
{
  imports = [ ./nvidia-driver-kernel-compat ];

  modules.nvidia = {
    enable = true;
    driverVersion = "575";   # pinned; or "latest" to track nixpkgs
    open = true;             # Blackwell/Turing+; false for pre-Turing
    prime.enable = false;    # true on a hybrid laptop (iGPU + dGPU)
  };
}
```

### Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn on the discrete NVIDIA GPU. |
| `driverVersion` | `"latest"` | Pinned release (`"570"`/`"575"`/`"590"`) or `"latest"`. |
| `open` | `true` | Open kernel modules (see above). |
| `prime.enable` | `false` | PRIME render offload for hybrid graphics. |
| `prime.intelBusId` | `"PCI:0:2:0"` | iGPU bus ID — find with `lspci`. |
| `prime.nvidiaBusId` | `"PCI:1:0:0"` | dGPU bus ID — find with `lspci`. |

### Adding / updating a pinned version

Add an entry to `driverVersions` (and to the `driverVersion` enum) with the new
`version` and hashes. To discover the hashes, add the entry with placeholder
hashes and let the build report the correct `got:` values, or copy them from
nixpkgs' driver metadata. Attach whichever `patchesOpen` your target kernel
needs.

## What else it turns on

Enabling the module is opinionated beyond the driver pin. It also sets
`services.xserver.videoDrivers = [ "modesetting" "nvidia" ]`, enables
`hardware.graphics` (with 32-bit support and `nvidia-vaapi-driver`), turns on
`modesetting`, coarse `powerManagement` and `forceFullCompositionPipeline`,
leaves `nvidiaSettings` off, and loads `nvidia`, `nvidia_modeset`, `nvidia_uvm`,
`nvidia_drm` and `i2c-nvidia_gpu` in **both** initrd and the main kernel module
list with `nvidia-drm.modeset=1` / `nvidia-drm.fbdev=1` — so the framebuffer
comes up on the NVIDIA GPU early instead of flickering through a simpledrm
handoff. Drop the pieces you don't want.

## Caveats

- **PRIME and GPU passthrough don't mix.** `prime` is only wired when
  `prime.enable = true`, on purpose: attaching PRIME keeps the driver bound in a
  way that fights dynamic VFIO rebind (single-GPU-passthrough / "GPU float to a
  VM" setups). Leave it off unless you actually render-offload on a hybrid
  laptop.
- **The pinned versions here are examples.** They're real, working releases, but
  you'll want to pin the version *you* validated against *your* card and kernel.
- **`open = false` needs different patches.** See the note above.
- The CachyOS 6.19 patch is pinned to a specific upstream commit; if that repo
  reorganizes you may need to re-pin the URL + hash.
