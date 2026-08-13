# disk-layout-guard

A `system.preSwitchChecks` guard that refuses to activate a generation whose
boot-critical storage does not actually exist on the running host. It checks
that every declared `fileSystems` block device and LUKS backing device is
present, that every declared ZFS pool is imported, and it flags the specific
trap where a config drops all `boot.initrd.luks.devices` while the running root
pool is still sitting on dm-crypt.

## The problem

`nixos-rebuild switch` will happily activate a generation whose `fileSystems`,
LUKS devices, or ZFS pools do not match the disks in the machine. Nothing during
the switch fails, because the running system already has its root mounted and
its pools imported -- the activation touches the bootloader and the systemd
mount units, not the live root.

The damage only lands at the **next boot**, when the initrd and stage-1 mounts
try to find storage the new generation describes and it is not there. By then
you are looking at an emergency shell on a machine that was working an hour ago,
with no error anywhere in the switch that produced it. Two shapes of this bite
in practice:

- A device path (`/dev/disk/by-partlabel/...`, an ESP, a LUKS container) that
  was renamed, re-provisioned, or copied from another host's config and never
  existed here.
- A config that once declared `boot.initrd.luks.devices` for an encrypted root,
  then had those declarations dropped -- while the disks are still LUKS. The
  pool imports fine right now because it was unlocked at the last boot, so
  everything looks healthy; the new initrd simply has no key setup and cannot
  unlock anything cold.

## The approach

At evaluation time the module reads `config.fileSystems`,
`config.boot.initrd.luks.devices`, and derives the set of ZFS pool names from
zfs mounts. It emits one `system.preSwitchChecks.diskLayout` script that:

- checks every declared `/dev/...` block device and LUKS backing device exists
  (`[ -e ]`);
- checks every declared pool is imported (`zpool list <pool>`);
- if pools are declared but **zero** LUKS devices are, inspects the running
  pool's vdevs (`zpool list -vHP`) for dm-crypt backing
  (`/dev/mapper/*`, `dm-uuid-CRYPT-*`, `dm-name-*`) and refuses if it finds any.

`preSwitchChecks` runs before `switch-to-configuration` does anything
destructive, so a non-zero exit aborts the switch with the running generation
still intact and a message that names exactly which device or pool is missing.

Mounts marked `nofail` or `noauto` are treated as non-boot-critical and skipped.

```nix
{
  imports = [ ./disk-layout-guard ];

  modules.diskLayoutGuard = {
    enable = true;
    ignoreDevices = [ "/dev/disk/by-partlabel/scratch" ];
  };
}
```

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `true` | Emit the guard when boot-critical storage is declared. |
| `ignoreDevices` | `[ ]` | Device paths exempted from the existence check. |

## Traps and caveats

### The bootloader is written before filesystems are checked

This is the whole reason the guard exists. `switch-to-configuration` installs
the bootloader early in activation, well before it restarts mount units. A bad
layout therefore produces a clean switch and a bricked next boot -- the failure
is separated from its cause by a reboot. A `preSwitchChecks` guard is the only
place to catch it *before* the bootloader is touched. An activation-script check
would run too late; a boot-time check would run on the already-broken generation.

### `preSwitchChecks` scripts run with essentially no PATH

These scripts execute in a bare environment -- you cannot assume `zpool`,
`mktemp`, or even `rm` are on `PATH`. Every binary must be referenced by its
full Nix store path, interpolated from `pkgs`/`config` at eval time
(`${config.boot.zfs.package}/sbin/zpool`, `${pkgs.coreutils}/bin/mktemp`). A
plain `zpool list` here fails with command-not-found and, depending on how you
wrote the conditional, can silently pass the check instead of running it.

### A failed vdev query must not read as "clean"

The dm-crypt backstop asks `zpool list -vHP <pool>` what the running pool sits
on. If that query fails -- `zpool` missing, the pool wedged, a non-zero exit --
it produces no output, and a naive `zpool ... | while read` masks the failure
behind the pipe's exit status: no vdevs matched, so the check "passes" and the
warning it exists to raise never fires. That is failing **open** on exactly the
regression this module is meant to catch. The guard instead runs the query with
its exit status captured (redirect to a temp file, then iterate the file), and
on any non-zero exit for a declared pool it emits a loud `INCONCLUSIVE` warning
to stderr rather than treating the pool as clean. The warning is non-fatal --
an unqueryable pool should not block every switch -- but it tells you the
dm-crypt safety check did not actually run, so you verify unlock-ability by hand
before dropping LUKS.

### The dm-crypt check only fires when LUKS is fully dropped

The encryption-layer check triggers only when pools are declared and
`boot.initrd.luks.devices` is empty. That is deliberate: it targets the
"someone deleted the LUKS block" regression, not partial edits. If you declare
some but wrong LUKS devices, the device-existence check is what catches you --
this second check is the backstop for the case where there is nothing left to
check against.

### It checks existence, not correctness

The guard proves the declared storage is *present*, not that it is the right
storage. A pool of the right name backed by the wrong disks, or a `by-partlabel`
path that resolves to an unrelated partition, passes. It closes the "declares
storage that isn't here" gap, which is the one that reliably bricks boots; it is
not a substitute for reviewing disk changes.

## Testing

[`test.nix`](./test.nix) is a NixOS VM test. It evaluates the guard for a matrix
of configs (missing device, `nofail` skip, `ignoreDevices`, missing pool,
disabled), then builds a real dm-crypt-backed ZFS pool inside the VM and proves
the guard refuses a config that drops LUKS while the pool still sits on dm-crypt,
and keeps passing while LUKS stays declared.

```console
$ nix-build test.nix --arg pkgs 'import <nixpkgs> { system = "x86_64-linux"; }'
```
