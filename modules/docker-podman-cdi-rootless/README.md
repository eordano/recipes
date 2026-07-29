# docker-podman-cdi-rootless

A single NixOS module that picks your container engine (Docker or rootless
Podman) behind one flag, and — crucially — keeps that choice *decoupled* from
the CDI/GPU-passthrough and rootless-hardening policy that every host wants
regardless of which engine it runs.

## The problem

Container config tends to get copy-pasted into every host: `virtualisation.docker`
here, `virtualisation.podman` there, GPU/CDI daemon settings smeared across
both. Two concerns are tangled together:

1. **Which engine** — Docker vs Podman (with the docker CLI compat shim).
2. **How it's hardened** — CDI for device passthrough, a rootless companion
   daemon, an explicit DNS resolver, auto-prune.

This module treats (2) as host-independent policy you wire once, and (1) as a
per-host flag.

## The trap it encodes

`features.cdi` must be set on **both** the root daemon **and** the rootless
daemon. The rootless daemon is a *separate* `dockerd` process with its own
`daemon.settings` block — it does not inherit the root daemon's config. If you
only set CDI on the root daemon, GPU workloads launched against the rootless
socket silently can't see the device.

Two related gotchas the defaults handle for you:

- **Rootless DNS**: the rootless daemon doesn't pick up the host resolver the
  way the root daemon does, so its containers need an explicit `dns` list or
  name resolution just fails. Default is a public resolver; override with a LAN
  resolver on hosts that must resolve internal names.
- **No `docker` group membership**: rootless Docker with `setSocketVariable`
  already hands unprivileged users their own socket via `DOCKER_HOST`. Adding
  a user to the root-equivalent `docker` group on top of that is gratuitous
  privilege escalation, so this module deliberately does not do it.

CDI is generic and harmless without a GPU — a separate NVIDIA/container-toolkit
module can enable the device plumbing, and it "just works" because the CDI
feature gate and rootless DNS already live here.

## Usage

Import `default.nix` as a module, then per host:

```nix
{
  modules.virtualisation.containers = {
    enable = true;
    # usePodman = true;                 # rootless Podman + docker compat shim
    # storageDriver = "overlay2";       # only if the FS supports it (see below)
    # podmanExtraPackages = [ pkgs.zfs ];  # userspace tools for your storage driver
    # dns = [ "192.0.2.1" ];            # LAN resolver for rootless containers
  };
}
```

## Options

| Option | Default | Notes |
| --- | --- | --- |
| `enable` | `false` | Turn the engine on. |
| `usePodman` | `false` | Rootless Podman + docker CLI compat instead of Docker. |
| `enableCdi` | `true` | *(Docker branch)* CDI on both root and rootless daemons. Needed for GPU passthrough. |
| `enableRootless` | `true` | *(Docker branch)* Run the rootless companion daemon and export `DOCKER_HOST`. |
| `storageDriver` | `null` | *(Docker branch)* `null` = auto-detect. Set only to match the real backing FS. |
| `podmanExtraPackages` | `[ ]` | *(Podman branch)* Storage-driver userspace tools for Podman (e.g. `pkgs.zfs`). |
| `dns` | `[ "1.1.1.1" ]` | *(Docker branch)* Resolvers for rootless-daemon containers. |
| `autoPrune` | `true` | *(Docker branch)* Periodic `docker system prune`. |

The branch annotations matter: the Podman branch consumes only `usePodman` and
`podmanExtraPackages`. Podman is rootless by construction and does its own CDI
and DNS handling, so `enableCdi`, `enableRootless`, `dns`, `storageDriver` and
`autoPrune` are read only when `usePodman = false`. The decoupling above is
about not re-deriving that policy per host, not about the two engines sharing
one implementation of it.

## Caveats

- **`storageDriver` must match the filesystem.** A driver the backing store
  doesn't support (`btrfs` on a non-btrfs host, `zfs` without the pool) will
  fail to start the daemon. Leaving it `null` lets Docker auto-detect, which is
  the safe default; set it explicitly only when you know the host FS.
- **Podman storage graph drivers need userspace tools.** On ZFS-backed hosts,
  put `pkgs.zfs` in `podmanExtraPackages` so Podman can drive that graph
  driver; same idea for other non-default drivers.
- The Podman branch is rootless with the docker-compat shim, so `docker ...`
  commands work but hit Podman. If you rely on Docker-daemon-specific behavior,
  keep `usePodman = false`.
