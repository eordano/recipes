# microvm-ram-snapshot-clones

Per-project throwaway dev VMs that spawn in **under a second**. A NixOS module
that gives you a `vm` command: `cd` into any project, run `vm`, and you're
dropped into a fresh, isolated, already-booted microvm whose workspace is that
directory.

## The problem

You want a real, isolated Linux environment per project — full systemd, real
services, a place to run untrusted build steps or agents — but:

- A container isn't a real machine (shared kernel, awkward systemd).
- A normal VM takes tens of seconds to boot and a fat disk image per instance.
- Cloud dev environments are slow to reach and cost money to idle.

## The key insight

**The "snapshot" is a frozen-RAM image, not a disk image.**

1. Boot the guest microvm exactly once.
2. `stop` the CPU over QMP, then `migrate` to `exec:zstd` — a compressed dump
   of the guest's live RAM.
3. A clone is that image piped back into a fresh QEMU via
   `-incoming "exec:zstd -d -c snapshot.zst"`. The guest wakes up
   **already booted** — no init, no service startup, no waiting.

Because the guest is a microvm booted straight from `-kernel`/`-initrd`/`init=`
with a shared `memfd` memory backend, restore is essentially the cost of
`zstd -d` plus SSH coming up.

### Storage: no block device at all

There is no disk image. The guest's only storage is two virtiofs mounts, and
the cache modes are load-bearing:

| Mount | Host source | Cache | Why |
|-------|-------------|-------|-----|
| `/nix/store` | host `/nix/store` | `cache=always` | Store is immutable; sharing it read-only means **clones cost zero store duplication** — every clone reuses the host closure. |
| workspace | the project dir | `cache=auto` | Bound read-write, so edits inside the clone **are edits on the host tree**. This is the whole point — you work on your real files. |

Nothing else survives a `stop`. The clone is disposable; your files are not,
because they were never *in* the clone.

### Clone identity is derived, not assigned

```
md5(realpath project-dir)[:8]  ->  VM name  "devvm-<hash>"
                               ->  SSH port  2200 + (0x<hash[:3]> % 800)
```

The same directory always maps to the same clone and port, so `vm` from a
project is idempotent — re-enter if running, spawn if not. **Trap:** the port
space is only 800 wide, so two *different* project dirs can collide on a port.
Fine for a personal workstation; think twice for many-user hosts.

### The base snapshot is cache-keyed on the guest closure

`vm update` records `nix hash path <guest-toplevel>` next to the snapshot. If
the hash is unchanged, it's a no-op. The base image only rebuilds when you
actually change the guest system definition, so the boot-once cost is paid
rarely.

## Usage

```nix
# flake.nix / configuration.nix
{
  imports = [ ./modules/microvm-ram-snapshot-clones ];

  modules.microvmClone = {
    enable = true;
    guestUser = "dev";
    guestSystem = self.nixosConfigurations.devvm-guest;  # see below
  };
}
```

Then, on the host:

```
cd ~/projects/foo
vm                 # spawn (or re-enter) the clone for this dir, drop into a shell
vm status          # name / port / snapshot size
vm list            # all clones: running / saved / dead
vm save "wip: refactoring the parser, mid-migration"   # freeze to disk (>20 char desc)
vm restore         # thaw a saved clone (spawn does this automatically too)
vm pause / vm resume   # stop and restart the clone's CPU over QMP
vm root-enter      # SSH in as root
vm logs            # journalctl -f from inside the clone
vm stop            # kill and forget the clone
sudo vm update     # (re)build the base snapshot; auto-runs at boot
vm completions bash|zsh|fish   # shell completions (also installed into /etc)
vm help            # full command list
```

`spawn` is the default when no subcommand is given, and `enter` / `init` /
`start` are aliases for it. Every directory-taking command accepts an optional
`[dir]`, defaulting to `$PWD`; a bare `vm <existing-dir>` spawns for that dir.

### Options

| Option | Default | Meaning |
|--------|---------|---------|
| `enable` | `false` | Turn the module on. |
| `guestSystem` | — (required) | An **evaluated** `nixosSystem` for the guest, including `microvm.nixosModules.microvm`. |
| `guestUser` | `"dev"` | Unprivileged user to SSH into inside the guest. |
| `guestWorkspace` | `/home/<guestUser>/workspace` | Where the project dir is mounted in the guest; interactive sessions `cd` here. |
| `snapshotDir` | `/var/lib/microvm-clone-snapshot` | Persistent base snapshot. |
| `clonesDir` | `/run/microvm-clones` | Per-clone state. On tmpfs by default, so clones vanish on reboot. |
| `snapshotAtBoot` | `true` | Build the base snapshot from a boot-time systemd oneshot. |
| `direnv` | `false` | Install a `layout_devvm` that auto-spawns a clone on `cd` and drops `vm`/`vm-run`/`vm-stop` shims into `.direnv/bin`. |
| `sshExtraOpts` | `""` | Extra SSH opts on every connection (e.g. `-i <key>`). |
| `sshKeySetup` | `""` | Shell run before SSH (e.g. materialize a key from the store into a 0600 tempfile). |
| `sshEnterOpts` | `""` | Extra SSH opts for interactive sessions only (e.g. GPG forwarding). |
| `forwardAgent` | `false` | Forward your ssh-agent (`ssh -A`) into interactive sessions. **Off by default** — see the security note below. |

## The guest system

`guestSystem` is an externally-evaluated microvm `nixosSystem`. The module
reaches into it for `microvm.kernel`, `microvm.initrdPath`,
`system.build.toplevel`, `microvm.mem`, `microvm.vcpu` and `boot.kernelParams`,
and boots those directly with QEMU (no bootloader, `init=<toplevel>/init`).

Your guest must satisfy three contracts:

1. **Be a microvm** — import `microvm.nixosModules.microvm` (from
   [astro/microvm.nix](https://github.com/astro/microvm.nix)) and set `mem` /
   `vcpu`.
2. **Mount the two virtiofs shares** by the tags the host uses: `ro-store` at
   `/nix/store` and `workspace` at `guestWorkspace`.
3. **Signal boot readiness** by touching `.boot-ready` in the workspace mount,
   and run an sshd the host can reach on the forwarded port (root and
   `guestUser`, key-based).

A minimal sketch (adapt to your own keys and packages):

```nix
# devvm-guest.nix — evaluated with nixpkgs.lib.nixosSystem and passed as guestSystem
{ modulesPath, lib, ... }:
{
  imports = [ /* microvm.nixosModules.microvm */ ];

  microvm.mem = 4096;
  microvm.vcpu = 4;

  # Host mounts /nix/store RO and the project dir RW; match the tags.
  microvm.shares = [
    { source = "/nix/store"; mountPoint = "/nix/.ro-store"; tag = "ro-store";
      proto = "virtiofs"; }
    { source = "/dev/null";  mountPoint = "/home/dev/workspace"; tag = "workspace";
      proto = "virtiofs"; }
  ];

  users.users.dev = {
    isNormalUser = true;
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... you@example.com" ];
  };
  users.users.root.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... you@example.com" ];

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };

  # Tell the host we've finished booting.
  systemd.services.boot-ready = {
    wantedBy = [ "multi-user.target" ];
    after = [ "sshd.service" ];
    serviceConfig.Type = "oneshot";
    script = "touch /home/dev/workspace/.boot-ready";
  };

  system.stateVersion = "24.05";
}
```

> The exact `microvm.shares` schema depends on your microvm.nix version — the
> point is: expose `ro-store`/`workspace` tags and mount them. The host passes
> `-device vhost-user-fs-pci,...,tag=ro-store` and `tag=workspace`.

## Caveats

- **KVM required** for usable speed (`accel=kvm:tcg` falls back to slow TCG).
- **x86_64 only** as written (`qemu-system-x86_64`, `-cpu max`). Adjust the
  QEMU binary and machine type for other arches.
- **Port collisions** — 800-wide derived port space (see above).
- **`vm update` is privileged** — it boots the base VM with virtiofsd and writes
  the snapshot into `snapshotDir`, which is created `0755 root root`; so it runs
  as root (systemd oneshot at boot, or `sudo vm update`).
- **`clonesDir` on tmpfs** means running clones and their RAM state die on
  reboot. That's intentional (disposable), but `vm save` is the escape hatch:
  it re-freezes a running clone to `save.zst`, which a later `vm` / `vm restore`
  thaws. Point `clonesDir` at persistent storage if you want clones to survive
  reboots.
- **The guest closure is shared, not copied** — a clone sees the host's live
  `/nix/store`. Don't GC the store out from under a running clone.
- **SSH host keys are ignored** (`StrictHostKeyChecking=no`,
  `UserKnownHostsFile=/dev/null`) because clones are ephemeral and share a base
  image. Fine for localhost-forwarded ports; don't reuse this SSH posture for
  anything routable.

## Security notes

- **Agent forwarding is opt-in.** `ssh -A` is **not** used unless you set
  `forwardAgent = true`. Because the whole point of a clone is to run
  possibly-untrusted build steps or agents, forwarding your ssh-agent would let
  anything inside the guest authenticate to any host your keys reach (GitHub,
  production, …) without ever seeing the key material. Leave it off unless the
  guest workload is trusted.
- **`clonesDir` is shared and world-writable, but sticky (`1777`).** The `vm`
  CLI writes pidfiles, sockets and saved state under `clonesDir`, and clone
  identity is a *predictable* `md5(realpath project-dir)`. The sticky bit stops
  one local user from renaming or deleting another user's clone state (which
  could otherwise plant a pidfile so `vm stop`/`vm list` kills an arbitrary PID,
  or redirect writes via a symlinked `CLONE_DIR`). On a multi-user host, give
  each user a private `clonesDir` (e.g. under `/run/user/$UID`) for full
  isolation; on a single-user workstation the default is fine.

## How it fits together

```
vm update                 vm (spawn)
   |                          |
   boot guest once            virtiofsd: /nix/store (RO, cache=always)
   QMP stop + migrate         virtiofsd: project dir (RW, cache=auto)
   -> zstd -> snapshot.zst    qemu -incoming "exec:zstd -d -c snapshot.zst"
                              QMP cont  ->  guest already booted
                              ssh -p <derived port> -> your shell in the workspace
```
