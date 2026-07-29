# nvidia-docker-gpu

A NixOS module that makes `docker run --gpus all ...` actually work with an
NVIDIA GPU — as a single import, not a half-configured trap.

## The problem

GPU passthrough to Docker on NixOS is a **two-part switch**, and enabling only
one half gives you a Docker daemon that starts fine but silently can't see the
GPU. `--gpus all` resolves to nothing, and the failure looks like a driver or
image problem rather than a config gap.

The two halves are:

1. **`hardware.nvidia-container-toolkit.enable`** — installs the Container
   Device Interface (CDI) spec generator, which describes the host GPU as a
   `nvidia.com/gpu=all` device.
2. **A Docker daemon with the `cdi` feature gate turned on** — without
   `daemon.settings.features.cdi = true`, dockerd ignores the generated CDI spec
   entirely, so the device that half 1 produced is never wired into containers.

It is easy to flip switch 1, assume you're done, and never realize switch 2 is
the load-bearing one. This module flips both, in one place.

## The traps this bakes in

- **The CDI gate must be set on *each* daemon.** Rootless Docker runs a
  *separate* dockerd with its own config; it does not inherit the rootful
  daemon's settings, so the `features.cdi` gate is applied to both.
- **Rootless containers get no DNS by default.** The rootless network stack does
  not inherit the host's `/etc/resolv.conf` the way the rootful daemon does, so
  containers on the rootless daemon fail to resolve names until you pin a
  resolver. `rootlessDns` does that (default `1.1.1.1`; override it with your own
  resolver).
- **Storage-driver / filesystem mismatch stops dockerd from starting.** If your
  Docker data-root lives on a filesystem whose graphdriver has to be chosen
  explicitly (e.g. ZFS), a wrong or default driver makes dockerd fail with
  "wrong filesystem" rather than fall back. Set `storageDriver` (and usually
  `dataRoot`) to match.

## Usage

```nix
{
  imports = [ ./nvidia-docker-gpu ];

  virtualisation.nvidiaDockerGpu.enable = true;
}
```

Then, after a rebuild:

```console
$ docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

should list the host GPU.

### Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the whole thing on. |
| `rootless` | `true` | Also run a rootless daemon (safer than adding your user to the root-equivalent `docker` group). The CDI gate is applied here too. |
| `rootlessDns` | `[ "1.1.1.1" ]` | DNS servers for the rootless daemon's bridge — without this, rootless containers can't resolve names. |
| `storageDriver` | `null` | Force a storage driver (e.g. `"zfs"`) when the default won't init on your data-root's filesystem. |
| `dataRoot` | `null` | Override Docker's data-root — useful on impermanent roots so images survive a reboot. |

## Caveats

- This module owns `virtualisation.docker`. If you already configure Docker
  elsewhere, merge the two or drop the overlapping settings — otherwise you'll
  get option conflicts.
- You still need the NVIDIA driver itself enabled (`hardware.nvidia` /
  `services.xserver.videoDrivers`), plus the GPU actually attached to the host
  (not passed through to a VM). This module handles the container plumbing, not
  the driver.
- Requires a NixOS new enough to expose `hardware.nvidia-container-toolkit`
  (NixOS **24.05+**, where it superseded the deprecated
  `virtualisation.docker.enableNvidia`), and a Docker new enough to honour CDI
  (**25+**).
- The module also sets `virtualisation.docker.enableOnBoot = true`, so the
  rootful daemon starts at boot rather than on socket activation.
- `dataRoot` is written into the **rootful** daemon's settings only; the
  rootless daemon keeps its own per-user data root.
