# systemd-boot-mirrored-esp

Two EFI system partitions on two different disks, kept byte-identical, plus a
**pinned recovery boot entry that the bootloader's own garbage collector cannot
reap** — and the ZFS mount barrier that makes "is the data actually there?" a
real precondition instead of a hope.

Three separate mechanisms, one module, because they fail as a unit: a mirror of
a broken ESP is a broken ESP, a recovery entry whose kernel was deleted is worse
than no recovery entry, and a recovery payload staged on an unmounted dataset is
silently not there.

## The problem

### 1. systemd-boot has no mirroring at all

nixpkgs' GRUB module has `boot.loader.grub.mirroredBoots`
(`nixos/modules/system/boot/loader/grub/grub.nix:276`) — a list of
`{ path, devices }` pairs, and the installer walks it and installs to every one.

The systemd-boot module has **no equivalent**. It writes exactly one `$BOOT`:

```nix
bootMountPoint =
  if cfg.xbootldrMountPoint != null then cfg.xbootldrMountPoint else efi.efiSysMountPoint;
```

(`nixos/modules/system/boot/loader/systemd-boot/systemd-boot.nix:65`.) One
mount point, one partition. If that NVMe dies, the machine does not boot, no
matter how well mirrored the root pool is. Mirroring the *pool* and forgetting
the *ESP* is the single most common gap in a "redundant" two-disk NixOS box:
`zroot` survives, and the firmware has nothing to load.

### 2. `configurationLimit` deletes the recovery kernel

This is the trap that gives the recipe its reason to exist, and it is worth
reading the upstream code rather than trusting a summary.

`boot.loader.systemd-boot.configurationLimit` is documented as "maximum number
of latest generations in the boot menu"
(`nixos/modules/system/boot/loader/systemd-boot/systemd-boot.nix:234`). It
sounds like a *display* limit. It is not. It is fed straight into the installer:

```python
CONFIGURATION_LIMIT = int("@configurationLimit@")
...
return configurations[-configurationLimit:]
```

(`systemd-boot-builder.py:33` and `:455`.) Everything downstream — the keep-set
for the ESP — is computed from that truncated list. Then:

```python
def garbage_collect(gc_roots: BootFileList) -> None:
    keep = {BOOT_MOUNT_POINT / gc_root.path for gc_root in gc_roots}

    def delete_path(e: os.DirEntry) -> None:
        if e.is_file(follow_symlinks=True) and Path(e.path) not in keep:
            os.remove(e.path)

    for e in os.scandir(BOOT_MOUNT_POINT / NIXOS_DIR):
        delete_path(e)
```

(`systemd-boot-builder.py:623`.) It `scandir`s `$BOOT/EFI/nixos` and deletes
**every file there that is not owned by one of the last N generations**. Not
"files it wrote". Not "files matching a pattern". Every file.

So the obvious way to build a recovery entry — boot into a known-good
generation, note its kernel and initrd under `EFI/nixos/`, hand-write a
`.conf` pointing at them — produces an entry that works today, works after the
next deploy, and is **dangling by the sixth deploy**, with
`configurationLimit = 5`. The failure mode is precisely inverted from what you
want: the recovery entry is present in the menu right up until you have done
enough deploys to actually need it, and then selecting it drops you at
`Error: not found` from the stub loader, on a machine you cannot log into.

Nothing warns. Nothing fails. The deploy that deletes the recovery kernel is
green.

### 3. And `nix-collect-garbage` deletes the source

The reflex fix is `boot.loader.systemd-boot.extraFiles`, which *is* re-copied
after garbage collection (see Trap 3 below for the exact ordering). It does not
solve this problem, because its type is `types.attrsOf types.path`
(`systemd-boot.nix:392`) — it can only pin something Nix can evaluate to a store
path. The kernel of a *past* generation is a store path you would have to write
literally into the config, and a literal `/nix/store/...` string carries no
string context, so nothing roots it and `nix-collect-garbage -d` deletes it. The
next deploy then fails in `install -Dp` with `No such file or directory`, in the
middle of bootloader installation, on a system whose ESP has already been
garbage collected.

The recovery payload has to survive **two independent garbage collectors** —
the ESP's and the Nix store's — plus a store wipe and a reinstall. The only
place that satisfies all of those is a plain directory on persistent storage,
outside the store and outside the ESP.

## Traps

### Trap 1 — the recovery entry must NOT be named `nixos-*.conf`

The entry-side garbage collection is regex-driven:

```python
for e in os.scandir(BOOT_MOUNT_POINT / "loader" / "entries"):
    match = re.fullmatch(r"nixos-.+\.conf", e.name)
    if match:
        delete_path(e)
```

(`systemd-boot-builder.py:633-636`.) Entries that *do not* match are left
alone — that is what makes a hand-placed recovery entry survivable at all. But
the natural name for a recovery entry is something like
`nixos-recovery.conf`, which matches `nixos-.+\.conf` exactly, is not in the
keep set, and is therefore deleted on every single install.

This module hard-**asserts** against it:

```
boot.mirroredEsp.recovery.entryFiles must not match nixos-*.conf
```

Name it `recovery-shell-init.conf`, `zz-recovery.conf`, anything that does not
start with `nixos-`. Use the `sort-key` field inside the entry to control where
it lands in the menu; the filename is not the ordering mechanism.

### Trap 2 — `extraInstallCommands` is the only hook that runs late enough

The installer script is assembled as:

```nix
finalSystemdBootBuilder = pkgs.writeScript "install-systemd-boot.sh" ''
  #!${pkgs.runtimeShell}
  set -euo pipefail
  ${systemdBootBuilder}/bin/systemd-boot "$@"
  ${cfg.extraInstallCommands}
'';
```

(`systemd-boot.nix:104-109`.) `extraInstallCommands` runs after the Python
builder has completely finished. Inside that builder the order is:

1. `garbage_collect(boot_files)` — prune `EFI/nixos` and `nixos-*.conf`
2. `write_boot_files(...)` — install the live generations
3. `write_loader_conf(...)`
4. `remove_extra_files()` — delete the previous run's `extraFiles`/`extraEntries`
5. `run([COPY_EXTRA_FILES])` — re-copy them

(`systemd-boot-builder.py:589-596`.) Anything that wants to place a file on the
ESP and have it *stay* must run after step 5. `extraInstallCommands` is the only
NixOS-level hook that does. This module emits exactly one block there:

```sh
if [ -d /var/lib/boot-recovery ]; then
  .../cp -f \
    /var/lib/boot-recovery/<kernel>.efi \
    /var/lib/boot-recovery/<initrd>.efi \
    /boot/EFI/nixos/
  .../cp -f \
    /var/lib/boot-recovery/recovery-shell-init.conf \
    /boot/loader/entries/recovery-shell-init.conf
fi
.../rsync -a --delete /boot/ /boot-mirror/
```

The restore is unconditional-per-deploy, not one-shot: it re-lays the files
after *every* garbage collection, so the pin is re-established as fast as it is
broken.

### Trap 3 — the mirror must be the LAST statement, and it must `--delete`

Order matters twice over:

- The `rsync` runs **after** the recovery restore. Reverse the two and the
  mirror ESP is a snapshot taken one instant before the recovery entry is put
  back — permanently missing exactly the entry you built the second disk for.
- `--delete` is not optional. Without it the mirror is a *union* of every
  generation ever installed: it grows monotonically, fills a 1 GiB FAT
  partition, and from then on rsync fails mid-copy and the mirror silently
  diverges from the primary. A mirror you cannot trust is worse than none,
  because you will try to boot it.

The trailing slashes are load-bearing: `rsync -a src/ dst/` copies the
*contents* of `src`; `rsync -a src dst/` creates `dst/src`. The module always
emits both slashes.

### Trap 4 — `mountpoint -q`, never `test -d`

The ZFS barrier polls with `mountpoint -q`, which reads the mount table. The
obvious alternative, `test -d /data`, is worse than useless: when a pool fails
to import, the mountpoint directory *still exists* on the underlying root
filesystem, empty. `test -d` succeeds, the barrier reports green, and every
consumer starts writing into the root filesystem at a path that is supposed to
be a 40 TB pool.

Then the pool imports late and ZFS mounts over the top. ZFS's `overlay`
property defaults to **on**, so the mount does *not* fail with "directory not
empty" — it succeeds and silently shadows everything that was written
underneath. The data is not lost, exactly; it is invisible, on the wrong
filesystem, filling the root pool, and it reappears the next time the data pool
fails to import. Nobody finds this quickly.

### Trap 5 — `after` AND `requires`, both, on the import unit

```nix
after = barrier.importUnits;
requires = barrier.importUnits;
```

Both, always. `requires` alone pulls the import service into the transaction but
imposes no ordering, so the barrier can run first and burn all its retries while
the import has not started. `after` alone orders correctly but only *if* the
import is in the same transaction — if nothing pulled it in, `After=` on an
inactive unit is a no-op and the barrier is ordered after nothing.

The barrier is also `wantedBy = [ "multi-user.target" ]` by default rather than
being pulled in solely by its consumers. A barrier that only runs when someone
needs it is a barrier whose failure is invisible on a host where that consumer
happens to be disabled.

### Trap 6 — there is no `.mount` unit to order against

The reflex is `RequiresMountsFor=/data`, or `after = [ "data.mount" ]`. Neither
exists for a natively-mounted ZFS dataset.

Datasets with `mountpoint=legacy` get a real `fileSystems` entry and therefore a
real systemd `.mount` unit. Datasets with a *native* `mountpoint=/data` are
mounted by `zfs-mount.service`
(`nixos/modules/tasks/filesystems/zfs.nix:945`), a single oneshot that runs
`zfs mount -a` for everything at once. systemd has no per-dataset unit to bind
to, and `zfs-mount.service` reports success even when an individual dataset
failed to mount.

So there is nothing to order against, and polling is not laziness — it is the
only mechanism that actually observes the property you care about. The backoff
is bounded (7 attempts, 1+2+4+…+64 = 127 s) so a genuinely dead pool fails the
unit instead of hanging boot forever.

### Trap 7 — the recovery restore fails OPEN, on purpose

`if [ -d <directory> ]` means: no payload staged, no restore, deploy proceeds.

That is deliberate. A host must be deployable before its recovery payload has
been staged — otherwise the very first deploy of a new machine is blocked on a
chicken-and-egg problem. But it also means a *disappeared* payload is silent,
and the most likely way for it to disappear is that it lives on a dataset that
did not mount. `[ -d /data/boot-recovery ]` is false when `/data` is an empty
unmounted directory, and the deploy is green.

If you stage the payload on a ZFS dataset, put a barrier on that dataset and
order something you actually watch behind it. The two halves of this module are
in the same file for that reason.

### Trap 8 — identify both ESPs by filesystem UUID

`primary.device` and `mirror.device` are applied with `mkForce`, overriding
whatever disko generated, and the README example uses `/dev/disk/by-uuid/`.

- `by-label` / `by-partlabel`: a disko layout that names both partitions `ESP`
  gives two partitions with the same label. Which one `/boot` resolves to is
  then a race, and the loser gets `rsync --delete`d onto the winner.
- `by-id` / `by-path`: encodes the controller slot. Move a disk after replacing
  the dead one and the mount points swap.
- `by-uuid`: `rsync` copies *files*, not the filesystem. The FAT volume ID lives
  in the boot sector and is never touched by the mirroring, so the two UUIDs
  stay distinct for the life of the partitions — including after a failover.

### Trap 9 — the mirror is not in NVRAM, but it is on the fallback path

`bootctl install` writes an EFI boot variable pointing at the **primary** ESP's
partition. The mirror is never registered: it is a passive replica that
systemd-boot has never heard of.

What makes it bootable anyway is that `bootctl install` also writes the
removable-media fallback, `EFI/BOOT/BOOTX64.EFI` — and `rsync -a --delete`
copies that to the mirror along with everything else. Most firmwares will boot
the second disk from the fallback path once the first is gone or deselected, and
all of them let you pick it manually from the firmware boot menu.

Test this **before** you need it, by disabling the primary disk in firmware
setup and booting. A mirror nobody has ever booted is a hypothesis.

### Trap 10 — `loader/random-seed` is per-installation state

`rsyncExcludes` defaults to `[ ]` — a byte-for-byte replica, which is what makes
the mirror boot with zero fixups.

The cost is that `loader/random-seed` is duplicated. `bootctl` treats that file
as per-installation state and warns against carrying it into a cloned image; the
seed is credited to the kernel entropy pool at boot and refreshed afterwards, so
two copies means the same seed can be credited twice — once from each ESP, if
you ever boot both. On a single machine with one live ESP at a time the exposure
is small, but if you would rather have systemd-boot regenerate it on first boot
of the mirror:

```nix
boot.mirroredEsp.rsyncExcludes = [ "loader/random-seed" ];
```

Decide once and write it down; the default is stated here so it is a choice
rather than an accident.

### Trap 11 — size the ESP for `configurationLimit`, then double the disks

A NixOS generation costs roughly 15 MB of kernel plus 60–120 MB of initrd on the
ESP, more with `boot.initrd.includeDefaultModules` and firmware blobs. At
`configurationLimit = 5` that is ~400–700 MB, plus the pinned recovery pair,
plus systemd-boot itself. A 512 MB ESP overflows; 1–1.5 GiB is comfortable.

An overflowing ESP is a nasty failure because it happens inside
`write_boot_files`, *after* `garbage_collect` has already run — the old
generations are gone and the new one did not fit.

## Usage

```nix
{
  imports = [ ./systemd-boot-mirrored-esp ];

  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 5;
  };

  boot.mirroredEsp = {
    enable = true;
    primary = {
      mountPoint = "/boot";
      device = "/dev/disk/by-uuid/1234-ABCD";
    };
    mirror = {
      mountPoint = "/boot-mirror";
      device = "/dev/disk/by-uuid/5678-EF01";
    };
    recovery = {
      enable = true;
      directory = "/persistent/boot-recovery";
      efiFiles = [
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-linux-6.12.0-bzImage.efi"
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-initrd-linux-6.12.0-initrd.efi"
      ];
      entryFiles = [ "recovery-shell-init.conf" ];
    };
  };

  boot.zfsMountBarriers = {
    data = {
      mountpoint = "/data";
      importUnits = [ "zfs-import-datapool.service" ];
    };
    data-archive = {
      mountpoint = "/data/archive";
      importUnits = [ "zfs-import-datapool.service" ];
    };
  };
}
```

A consumer then orders itself behind a barrier:

```nix
systemd.services.my-archiver = {
  after = [ "wait-for-zfs-data-archive.service" ];
  requires = [ "wait-for-zfs-data-archive.service" ];
};
```

### Staging the recovery payload (one-time, imperative)

The payload is deliberately *not* declarative — that is the whole point. Boot
the generation you want to be able to fall back to, then, as root:

```sh
mkdir -p /persistent/boot-recovery
cp /boot/EFI/nixos/*-linux-*-bzImage.efi   /persistent/boot-recovery/
cp /boot/EFI/nixos/*-initrd-linux-*.efi    /persistent/boot-recovery/
cp /boot/loader/entries/nixos-generation-<N>.conf \
   /persistent/boot-recovery/recovery-shell-init.conf
```

Then edit the copied `.conf`: rename the `title`, add a `sort-key` so it lands
where you want in the menu, and consider appending `init=…` overrides such as
`systemd.unit=rescue.target`. Leave the `linux` and `initrd` lines pointing at
`/EFI/nixos/<the exact filenames you copied>` — those filenames go into
`recovery.efiFiles` verbatim.

The `options init=/nix/store/…-nixos-system-…/init` line is the part that keeps
this honest: it names a store path. Keep that generation pinned as a Nix GC root
(`nix-env -p /nix/var/nix/profiles/system --list-generations`, then do not
`--delete-older-than` past it) or accept that the recovery entry boots a kernel
and initrd into an emergency shell without a working `init`. For a
"get me a shell on this box" recovery entry the latter is often enough — the
initrd is self-contained — but know which one you built.

Verify after every deploy that changes the kernel:

```sh
ls -l /boot/EFI/nixos/ /boot-mirror/EFI/nixos/
diff -r /boot /boot-mirror && echo "mirror clean"
```

## Options

| Option | Default | Effect |
| --- | --- | --- |
| `boot.mirroredEsp.enable` | `false` | Nothing applies until this is on. |
| `boot.mirroredEsp.primary.mountPoint` | `"/boot"` | Must equal the partition systemd-boot writes to (asserted). |
| `boot.mirroredEsp.primary.device` | `null` | `mkForce`d into `fileSystems`. Use `by-uuid` — Trap 8. |
| `boot.mirroredEsp.mirror.enable` | `true` | Emit the mirroring rsync. |
| `boot.mirroredEsp.mirror.mountPoint` | `"/boot-mirror"` | Passive replica; must differ from primary (asserted). |
| `boot.mirroredEsp.mirror.device` | `null` | `mkForce`d into `fileSystems`. |
| `boot.mirroredEsp.mountOptions` | `[ "umask=0077" ]` | Added to **both** ESPs. Concatenates with disko's `defaults`. |
| `boot.mirroredEsp.rsyncFlags` | `[ "-a" "--delete" ]` | See Trap 3 before changing. |
| `boot.mirroredEsp.rsyncExcludes` | `[ ]` | `--exclude=` list. See Trap 10. |
| `boot.mirroredEsp.recovery.enable` | `false` | Restore the pinned payload after every install. |
| `boot.mirroredEsp.recovery.directory` | `"/var/lib/boot-recovery"` | Must be outside the store and outside the ESP (asserted). |
| `boot.mirroredEsp.recovery.efiFiles` | `[ ]` | Basenames copied into `<ESP>/EFI/nixos/`. |
| `boot.mirroredEsp.recovery.entryFiles` | `[ ]` | Basenames copied into `<ESP>/loader/entries/`. Rejected if `nixos-*.conf` — Trap 1. |
| `boot.mirroredEsp.coreutilsPackage` | `pkgs.coreutils` | Provides `cp`. |
| `boot.mirroredEsp.rsyncPackage` | `pkgs.rsync` | Provides `rsync`. |
| `boot.mirroredEsp.utilLinuxPackage` | `pkgs.util-linux` | Provides `mountpoint` for the barriers. |
| `boot.zfsMountBarriers.<name>.mountpoint` | — | Path polled with `mountpoint -q`. |
| `boot.zfsMountBarriers.<name>.importUnits` | — | Placed in both `after` and `requires` — Trap 5. |
| `boot.zfsMountBarriers.<name>.attempts` | `7` | Exponential backoff, 127 s total. |
| `boot.zfsMountBarriers.<name>.wantedBy` | `[ "multi-user.target" ]` | Keep it, so failures are visible. |

Barriers are independent of `boot.mirroredEsp.enable`; a host can use either
half alone.

## Testing

[`test.nix`](./test.nix) is a real NixOS VM test. Run it standalone, no flake
needed:

```console
$ nix-build test.nix --arg pkgs 'import <nixpkgs> { system = "x86_64-linux"; }'
```

or from a flake, `pkgs.callPackage ./modules/systemd-boot-mirrored-esp/test.nix { }`.

The VM boots UEFI via `virtualisation.useBootLoader`, gets a second 512 MiB
virtio disk formatted as the mirror ESP and a third one for the pinned payload,
and then rolls through four generations with `configurationLimit = 2` so the
installer's garbage collector really fires.

What it proves:

- **The two ESPs are byte-identical.** Not "both non-empty": the same recursive
  file *and directory* listing, the same `sha256sum` for every regular file, a
  clean `diff -r`, and a floor on file count and total size so the comparison
  cannot pass vacuously on an empty ESP. A stray file planted in the mirror
  beforehand is gone afterwards, which is what proves `--delete` (Trap 3).
- **The recovery kernel, initrd and loader entry are present** after every
  install, on *both* ESPs, byte-identical to what was staged.
- **The recovery entry survives generation garbage collection.** Four
  generations with three distinct initrds are built; the test asserts the
  initrds really are distinct (otherwise the whole check would be vacuous),
  that generations 1 and 2 lose their loader entries, that generation 2's
  initrd *file* is deleted from `EFI/nixos` — and that through all of it the
  pinned payload is still there and the entry's `linux`/`initrd` lines still
  resolve to existing, correct files.
- **It actually boots.** After the last install, `loader.conf` is pointed at
  the recovery entry, the VM is rebooted, and the test asserts a unique marker
  from the pinned entry's `options` line shows up in `/proc/cmdline`. That
  string exists nowhere else, so it can only have come from firmware loading
  the pinned kernel and initrd off the ESP.

The instrument that keeps the survival assertions honest: before the first
install the test plants two *unpinned* decoys — one file in `EFI/nixos` and one
`nixos-*.conf` in `loader/entries` — and asserts that both are **gone** after
the install. If they were still there, "the recovery files survived" would only
mean "the collector never ran", and the test says so instead of passing.

Two things the module declares cannot be observed from inside a VM at all,
because `qemu-vm.nix` replaces `fileSystems` wholesale with
`mkVMOverride config.virtualisation.fileSystems`: the `mkForce`d ESP devices
and the `umask=0077` mount options. Those are checked in a plain non-VM
evaluation at the top of `test.nix`, together with the two assertions from
Trap 1 (`nixos-*.conf` entry name) and the payload-inside-the-ESP guard. The VM
then mounts both ESPs by hand with exactly the options that evaluation proved
the module declares.

Not covered: firmware-level failover (pulling the primary disk and booting the
mirror ESP), which needs a second NVRAM boot entry and disk removal the test
driver cannot express; Secure Boot signing of the mirrored/pinned binaries; and
`xbootldrMountPoint` layouts, which the module does not support for mirroring
anyway.

## Caveats

- **Nothing verifies the recovery entry.** The module guarantees the files are
  re-laid after every install and that their names cannot be garbage collected.
  It cannot check that the `.conf` points at kernels that exist, or that they
  boot. Boot it once a quarter.
- **The mirror is refreshed only when the bootloader is installed.** That is
  every `nixos-rebuild switch`/`boot`, but *not* on a `nixos-rebuild test`, and
  not if you hand-edit something on the primary ESP. `diff -r` is the check.
- **XBOOTLDR is not supported for mirroring.** With
  `boot.loader.systemd-boot.xbootldrMountPoint` set, entries and kernels live on
  XBOOTLDR while the EFI binaries live on the ESP, so a single-partition mirror
  is not a bootable copy. The assertion forces `primary.mountPoint` to the
  partition that receives entries; mirroring the other one is out of scope.
- **`fileSystems.<p>.options` concatenates.** `mountOptions` is *added* to
  whatever else declared the mount; it does not replace it. If disko already
  contributes `defaults`, the result is `[ "defaults" "umask=0077" ]`.
- **Secure Boot changes the picture.** With a shim/`sbctl` setup the mirrored
  binaries must be signed with the same keys, and a hand-staged recovery kernel
  is unsigned unless you signed it before staging. Sign first, stage second.
- **This is not a substitute for a rescue USB.** It covers "one disk died" and
  "the last five generations are all broken". It does not cover a corrupted
  root pool, and it never will — see
  [`remote-luks-unlock`](remote-luks-unlock.md) for getting into a box whose
  initrd is waiting for a passphrase, and
  [`zfs-native-encryption-keys`](zfs-native-encryption-keys.md) for the key
  handling that has to work before any of this matters.
