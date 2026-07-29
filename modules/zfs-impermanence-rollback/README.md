# zfs-impermanence-rollback

Wipe-on-boot for ZFS: declare which datasets get rolled back to a blank
snapshot inside the initrd, and get the systemd ordering, the `neededForBoot`
guard rail and the loud-failure behaviour that make the wipe an actual
guarantee instead of a hope.

The interesting part of this recipe is **not** rolling back `/`. Everyone gets
that right, because there is exactly one obvious unit to order against. The
interesting part is the **second** dataset — usually `/home` — where the
obvious answer is wrong in a way that produces a machine which boots fine,
looks right, passes every check you think to run, and quietly keeps state
forever.

```nix
zfsWipeOnBoot = {
  enable = true;
  datasets = {
    root = { dataset = "rpool/local/root"; mountPoint = "/"; };
    home = { dataset = "rpool/local/home"; mountPoint = "/home"; };
  };
};
```

## The problem

"Erase your darlings" impermanence has two halves:

1. **Put the state you want back somewhere durable.** That is
   `nix-community/impermanence`'s `environment.persistence.<root>` — bind
   mounts from a persistent dataset onto an ephemeral root.
2. **Destroy everything else on every boot.** That is a `zfs rollback` in the
   initrd, before anything mounts the dataset.

nixpkgs implements neither, and the impermanence flake implements only the
first. There is no `fileSystems.<name>.wipeOnBoot`, no `boot.zfs.rollback*`,
nothing. `nixos/modules/tasks/filesystems/zfs.nix` (~1500 lines, covering
import, key loading, auto-snapshot, scrub, trim, ZED, expand) has no notion of
rolling anything back. So every impermanence host in the world carries a
hand-written copy of the same twelve-line unit, and the copies differ in ways
their authors did not intend.

Half of them are also still written against **scripted stage 1**:

```nix
boot.initrd.postDeviceCommands = lib.mkAfter ''
  zfs rollback -r rpool/local/root@blank
'';
```

That form has no ordering semantics whatsoever — it is a shell fragment
concatenated into one big script — and under the systemd initrd it is a
*removed* option: `nixos/modules/system/boot/systemd/initrd.nix` lists
`postDeviceCommands` in its `obsoleteOpt` block with the message "systemd stage
1 does not support `boot.initrd.postDeviceCommands`". A host that flips
`boot.initrd.systemd.enable = true` and forgets to port its rollback does not
get a warning about a *disabled* wipe; it gets an evaluation error, which is
the good case. A host that ports it *incorrectly* gets no error at all.

This module handles the second half only. Pair it with the impermanence flake,
or with plain bind mounts, for the first.

---

## Trap 1 — the anchor must be `sysroot.mount`, even for `/home`

This is the whole reason the recipe exists.

Write the root wipe and there is one candidate unit and it is right:

```nix
boot.initrd.systemd.services.rollback-root = {
  wantedBy = [ "initrd.target" ];
  after    = [ "zfs-import-rpool.service" ];
  before    = [ "sysroot.mount" ];          # <-- the anchor
  unitConfig.DefaultDependencies = "no";
  serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
  script = "zfs rollback -r rpool/local/root@blank";
};
```

Now add `/home`. The symmetric-looking edit is to copy the unit and change
`sysroot.mount` to the mount unit for `/home`:

```nix
  before = [ "sysroot-home.mount" ];        # <-- looks right. is not.
```

It even works, on the host you tested it on, today. Here is why it is not a
guarantee.

### What the initrd actually does

`neededForBoot` filesystems are written into a separate fstab that is handed to
systemd in the initrd (`nixos/modules/tasks/filesystems.nix`):

```nix
initrdFstab = pkgs.writeText "initrd-fstab" (
  makeFstabEntries (filter utils.fsNeededForBoot fileSystems) { }
);
...
boot.initrd.systemd.storePaths = [ initrdFstab ];
boot.initrd.systemd.managerEnvironment.SYSTEMD_SYSROOT_FSTAB = initrdFstab;
boot.initrd.systemd.services.initrd-parse-etc.environment.SYSTEMD_SYSROOT_FSTAB = initrdFstab;
```

`systemd-fstab-generator` turns each entry into a `/sysroot`-prefixed mount
unit: `/` → `sysroot.mount`, `/home` → `sysroot-home.mount`, `/var/log` →
`sysroot-var-log.mount`. The two are **not** peers:

- `sysroot.mount` is pulled by `initrd-root-fs.target`.
- everything else is pulled by `initrd-fs.target`, which is
  `After=initrd-parse-etc.service`, which is `Requires=/After=initrd-root-fs.target`.
- and, independently, systemd.mount(5) states: *"If a mount unit is beneath
  another mount unit in the file system hierarchy, both a requirement
  dependency and an ordering dependency between both units are created
  automatically."* `sysroot-home.mount` is beneath `sysroot.mount`, so it
  gains `Requires=sysroot.mount` and `After=sysroot.mount` for free.

So `sysroot.mount` is a **strictly earlier, strictly more certain** point in
the initrd timeline than any other `sysroot-*.mount`. Ordering the wipe before
`sysroot.mount` transitively orders it before every one of them. That is the
"ordering between the two mount units" that the anchor leans on, and it is why
`before = [ "sysroot.mount" ]` is the correct answer for a dataset mounted at
`/home` just as much as for one mounted at `/`.

### Why the narrow anchor fails silently

`Before=` is not a requirement. systemd.unit(5): ordering is orthogonal to
`Requires=`/`Wants=`, and a unit that is not part of the transaction imposes no
ordering at all. **A `Before=` naming a unit that does not exist is not an
error, not a warning, not a failed assertion. It is a no-op, and systemd logs
nothing.**

`sysroot-home.mount` does not exist unless `/home` is `neededForBoot`. And
`neededForBoot` is a separate line, in a separate file, usually written by
whoever set up disko — not by whoever wrote the rollback unit. Drop it, move
`/home` to a different mount point, `mkForce` the `fileSystems` entry from a
hardware module, split `/home` into per-user datasets — any of those removes
the unit, and the `Before=` evaporates with it.

At that point the wipe service has `DefaultDependencies=no` (mandatory: with
default dependencies a service is `After=basic.target`, far too late) and one
surviving constraint, `After=zfs-import-rpool.service`. Nothing orders it
against the rest of the boot. Two things then happen, both quiet:

1. It can run **after** stage 2 has already mounted `/home` — and a mounted
   dataset cannot be rolled back while anything holds it open:
   `cannot rollback 'rpool/local/home': mountpoint or dataset is busy`.
2. More likely, it never runs at all. `initrd-cleanup.service` is literally
   `ExecStart=systemctl --no-block isolate initrd-switch-root.target`, and
   `isolate` stops every unit that is not a dependency of the isolated target.
   A `WantedBy=initrd.target`, `DefaultDependencies=no` service with no
   relationship to `initrd-switch-root.target` is exactly that: it gets a stop
   job and is torn down, started or not.

Either way `initrd.target` only `Wants=` its filesystems, the boot proceeds,
you land at a login prompt, `/home` is intact, and **that is what you asked
for as far as anything can tell.** No unit is red. No message mentions the
wipe. The threat model is gone and the only symptom is that last month's
browser profile is still there — which reads as a feature.

`sysroot.mount` cannot disappear. Every bootable Linux system has a root
filesystem, and `/` is unconditionally in `utils.pathsNeededForBoot`
(`nixos/lib/utils.nix`), so its mount unit is in the initrd regardless of what
anyone writes in `fileSystems`.

**This module emits both**, `sysroot.mount` first:

```
[Unit]
After=zfs-import-rpool.service
Before=sysroot.mount sysroot-home.mount
DefaultDependencies=no
```

The dataset's own mount unit is redundant given the anchor. It is there so the
next reader can see which mount this unit is protecting without deriving the
escaped name in their head.

---

## Trap 2 — `neededForBoot` is not a performance hint

Because Trap 1 hinges on it, this module **sets** it rather than hoping:

```nix
fileSystems.<mountPoint>.neededForBoot = true;   # enforceNeededForBoot, default true
```

and then asserts on the *effective* value anyway, so a `mkForce` from a
hardware module elsewhere is caught at eval:

```
zfsWipeOnBoot.datasets.home wipes rpool/local/home mounted at /home, but that
filesystem is not neededForBoot.

Its `sysroot-home.mount` unit therefore does not exist in the initrd, the mount
happens in stage 2 instead, and the wipe is unordered with respect to it.
```

The check is `utils.fsNeededForBoot`, i.e. `fs.neededForBoot || elem
fs.mountPoint pathsNeededForBoot`, not the raw option — so `/` never trips it
spuriously.

One shape defeats the *setting* while leaving the assertion intact, which is
the correct trade: if a host writes the whole filesystem entry with `mkForce`,

```nix
fileSystems."/home" = lib.mkForce {
  device = "rpool/local/home";
  fsType = "zfs";
  options = [ "zfsutil" ];
  neededForBoot = true;      # <-- you now own this line
};
```

then priority 50 replaces the submodule wholesale and this module's
`neededForBoot = true` (priority 100) is discarded. That is fine as long as the
forced value says `true`; if it does not, the assertion fires at eval instead
of the wipe failing at 3 a.m.

Setting `neededForBoot` has a visible side effect worth knowing: nixpkgs adds
`x-initrd.mount` to the filesystem's options
(`nixos/modules/tasks/filesystems.nix`, the `config.options` `mkMerge`). If you
diff a host's `fileSystems."/home".options` before and after adopting this
module, that is the expected change.

---

## Trap 3 — a failed wipe is a successful boot

`initrd.target` declares `Wants=initrd-root-fs.target initrd-root-device.target
initrd-fs.target initrd-usr-fs.target initrd-parse-etc.service` — `Wants=`,
not `Requires=`. A `wantedBy = [ "initrd.target" ]` oneshot that exits non-zero
does not stop anything. `zfs rollback` failing because the snapshot was never
created is therefore indistinguishable, from the outside, from it succeeding.

So this module defaults `failHard = true`, which emits the same pair systemd's
own initrd units use:

```
OnFailure=emergency.target
OnFailureJobMode=replace-irreversibly
```

`replace-irreversibly` matters: without it the pending boot transaction can
still complete around the emergency job. This is exactly what
`initrd-parse-etc.service`, `initrd-fs.target` and `initrd-cleanup.service`
ship with upstream.

And because "the snapshot does not exist" is by far the most common cause, the
generated script checks first and says so, instead of leaving you to decode
`cannot open 'rpool/local/home@blank': dataset does not exist` from a
half-second of scrollback:

```
zfs-wipe-on-boot: rpool/local/home@blank does not exist. Refusing to boot with
state that was supposed to be discarded. Create it with:
  zfs snapshot rpool/local/home@blank
```

**`failHard = false` on hosts you cannot reach.** `emergency.target` in the
initrd is a serial console prompt. If the host has neither
`boot.initrd.systemd.emergencyAccess = true` nor initrd SSH (see
[`remote-luks-unlock`](remote-luks-unlock.md)), a hard fail is a brick that
needs someone with physical access. On such hosts prefer `failHard = false` and
a boot-time alert, and accept that you must monitor for the failure yourself.

---

## Trap 4 — `-r` silently eats every snapshot of that dataset, every boot

`zfs rollback` refuses by default to roll back to anything but the most recent
snapshot:

```
cannot rollback to 'rpool/local/home@blank': more recent snapshots or bookmarks exist
```

which means an unattended wipe **must** pass `-r` — the moment any snapshot
timer, replication job or `zfs-auto-snapshot` touches the dataset, a rollback
without `-r` fails on every subsequent boot. So `recursive` defaults to `true`.

The consequence, from zfs-rollback(8): `-r` *"Destroy any snapshots and
bookmarks more recent than the one specified."* On a dataset carrying
`com.sun:auto-snapshot=true` that is: **destroy the entire snapshot history of
that dataset on every single boot**, without a word.

Disko templates make this easy to get wrong, because the sensible-looking
default for a `home` dataset is to snapshot it:

```nix
"safe/home" = {
  type = "zfs_fs";
  mountpoint = "/home";
  options."com.sun:auto-snapshot" = "true";    # correct for a PERSISTENT /home
};
```

If `/home` is wiped on boot, that property must be `"false"`, and the durable
copies live on the persistent dataset instead. Keep the two shapes clearly
separate in your disko templates and never let a "wipe /home" host inherit the
"keep /home" dataset options.

ZFS dataset properties are live state, not declarative config: disko's
`options` apply at pool-creation time and never re-run. A module cannot detect
this at eval, so it is documentation and a habit, not an assertion. Check it
by hand:

```sh
zfs get -r com.sun:auto-snapshot rpool/local
```

---

## Trap 5 — the blank snapshot must predate the first boot, idempotently

`@blank` has to exist before the wipe first runs, which means at install time,
which means a disko `postCreateHook`:

```nix
"local/home" = {
  type = "zfs_fs";
  options = { mountpoint = "/home"; canmount = "noauto"; };
  postCreateHook = "zfs snapshot rpool/local/home@blank";
};
```

Write it **idempotently**. `postCreateHook` re-runs on any repeat of the create
step, and a second `zfs snapshot` of an existing name fails the whole disko
run:

```nix
postCreateHook = ''
  zfs list -t snapshot -H -o name | grep -qE '^rpool/local/home@blank$' \
    || zfs snapshot rpool/local/home@blank
'';
```

For a dataset added to an *existing* host there is no install step to hook, so
this module offers `onMissingSnapshot = "create"`: it snapshots the current
contents under that name and continues, logging clearly that this boot kept its
state. Use it for exactly one boot, then set it back to `"fail"` — left on, it
turns "the snapshot is missing" from a loud stop into an automatic
re-baselining of whatever happened to be on disk.

---

## Trap 6 — make sure nothing else mounts the dataset first

The wipe races anything that mounts the dataset outside the mount units you
ordered against. Two upstream behaviours are on your side, and both are worth
knowing so you do not accidentally opt out:

- **Import does not mount.** The initrd import runs `zpool import -d … -N …`
  (`nixos/modules/tasks/filesystems/zfs.nix`); `-N` is "import without
  mounting". Nothing in the pool is mounted by the import itself.
- **The import unit is ordered before every one of the pool's mounts.** The
  same file computes `getPoolMounts` — the `/sysroot`-prefixed, escaped mount
  unit name for each of that pool's `neededForBoot` filesystems — and sets both
  `requiredBy` and `before` to it. That is why this module derives its
  `After=zfs-import-<pool>.service` from the *dataset's own pool prefix* rather
  than from an option you could get wrong.

What can still bite you is stage 2. `zfs-mount.service` mounts datasets with a
real `mountpoint` property and `canmount=on`. For a wiped dataset that is at
best a double mount and at worst a mount of the pre-rollback state over the
top. Two ways out, both used in the wild:

- `mountpoint = "legacy"` — ZFS will not mount it; only the fstab/mount unit
  does. Simplest.
- `mountpoint = "/home"` + `canmount = "noauto"` + mount option `zfsutil` —
  keeps the property useful for `zfs mount` by hand while `zfs mount -a` skips
  it. Hosts that go further disable the unit outright with
  `systemd.services.zfs-mount.enable = false`.

Pick one per host and be consistent; mixing them is how a dataset ends up
mounted twice with the wipe applied to the copy nobody is using. This module
warns when `fileSystems.<mountPoint>.device` is not the dataset it was told to
roll back, which catches the most common form of that mistake.

---

## Trap 7 — encryption changes the ordering, not the anchor

With the pool inside LUKS, the import unit needs its own dependency on the
cryptsetup unit; the wipe inherits the ordering transitively and needs no
change:

```nix
boot.initrd.systemd.services."zfs-import-rpool" = {
  after    = [ "systemd-cryptsetup@crypted.service" ];
  requires = [ "systemd-cryptsetup@crypted.service" ];
};
```

With ZFS **native** encryption the key load happens inside the import unit
itself, so there is nothing extra to order — see
[`zfs-native-encryption-keys`](zfs-native-encryption-keys.md) for how the key
gets into the initrd in the first place. Either way the per-dataset `after`
option here is for units the *import* depends on, not for the wipe.

---

## Trap 8 — what must be on the persistent dataset, or the wipe rotates it

A wipe that includes `/` destroys machine identity unless it is persisted
explicitly. The two that hurt:

- `/etc/machine-id` — regenerated every boot. Breaks the persistent journal
  (`/var/log/journal/<machine-id>/` becomes a new directory each boot, and the
  old ones are never read), systemd's `ConditionFirstBoot`, and anything keyed
  on it.
- **SSH host keys** — regenerated every boot, so every client gets a host-key
  mismatch on every reboot, and the fleet-wide muscle-memory response to that
  is to delete the `known_hosts` line, which is exactly the reflex a real
  man-in-the-middle needs you to have. Point them at the persistent dataset
  with `services.openssh.hostKeys` and check the paths actually resolve there.

Also persist `/var/lib/nixos` (UID/GID allocations — without it, dynamic users
renumber and file ownership on persisted data drifts) and `/var/lib/systemd`.

For a wiped `/home` specifically, remember that per-user persistence
bind-mounts into a home directory that the wipe just emptied. The user's home
must be recreated (it is, by `systemd-tmpfiles` / `users.users.<n>.home`) with
the right ownership *before* the bind mounts land, and anything not listed is
gone. The failure mode is not data loss you notice — it is a login that
silently resets a setting you changed three weeks ago.

---

## Usage

```nix
{
  imports = [ ./zfs-impermanence-rollback ];

  boot.initrd.systemd.enable = true;

  zfsWipeOnBoot = {
    enable = true;
    datasets = {
      root = { dataset = "rpool/local/root"; mountPoint = "/"; };
      home = { dataset = "rpool/local/home"; mountPoint = "/home"; };
    };
  };

  fileSystems."/persist".neededForBoot = true;

  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [ "/var/lib/nixos" "/var/lib/systemd" ];
    files = [ "/etc/machine-id" ];
  };

  services.openssh.hostKeys = lib.mkForce [
    { path = "/persist/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
  ];
}
```

Root inside LUKS, headless, no console access:

```nix
zfsWipeOnBoot = {
  enable = true;
  datasets.root = {
    dataset    = "rpool/local/root";
    mountPoint = "/";
    failHard   = false;                            # see Trap 3
    after      = [ "systemd-cryptsetup@crypted.service" ];
  };
};
```

Adding a wiped `/home` to a host that already has one, for a single boot:

```nix
zfsWipeOnBoot.datasets.home = {
  dataset           = "rpool/local/home";
  mountPoint        = "/home";
  onMissingSnapshot = "create";      # then change back to "fail"
};
```

---

## Options

| Option | Default | Effect |
| --- | --- | --- |
| `zfsWipeOnBoot.enable` | `false` | Nothing is emitted until this is on. |
| `zfsWipeOnBoot.package` | `config.boot.zfs.package` | `zfs` binary put on the unit's `PATH`. |
| `zfsWipeOnBoot.snapshot` | `"blank"` | Default snapshot name for every entry. |
| `zfsWipeOnBoot.namePrefix` | `"zfs-wipe"` | Units are `<prefix>-<key>.service`. |
| `zfsWipeOnBoot.enforceNeededForBoot` | `true` | Sets `fileSystems.<mountPoint>.neededForBoot = true`. See Trap 2. |
| `zfsWipeOnBoot.datasets` | `{ }` | Attrset of entries, keyed by unit-name suffix. |
| `…datasets.<n>.enable` | `true` | Turn one entry off without deleting it. |
| `…datasets.<n>.dataset` | *required* | Full dataset name; its pool prefix picks the import unit. |
| `…datasets.<n>.snapshot` | `zfsWipeOnBoot.snapshot` | Snapshot name without the `@`. |
| `…datasets.<n>.mountPoint` | `null` | Enables the `neededForBoot` guard rail and assertions. |
| `…datasets.<n>.recursive` | `true` | `zfs rollback -r`. See Trap 4. |
| `…datasets.<n>.onMissingSnapshot` | `"fail"` | `fail` / `create` / `ignore`. See Trap 5. |
| `…datasets.<n>.failHard` | `true` | `OnFailure=emergency.target`. See Trap 3. |
| `…datasets.<n>.after` | `[ ]` | Extra `After=`, e.g. a cryptsetup unit. |
| `…datasets.<n>.requires` | `[ ]` | Extra `Requires=`. |

Emitted per entry:

```
[Unit]
After=zfs-import-<pool>.service
Before=sysroot.mount <escaped mount unit>
DefaultDependencies=no
OnFailure=emergency.target
OnFailureJobMode=replace-irreversibly

[Service]
Type=oneshot
RemainAfterExit=true
```

---

## Verifying the wipe actually happens

Do not trust "it booted". Three checks, in increasing strength:

1. **The canary.** `touch ~/canary-do-not-persist`, reboot, look. Thirty
   seconds, and it catches
   every failure mode in this document.

2. **The unit ran, and ran early.** The initrd journal is flushed into the main
   journal at switch-root, so:

   ```sh
   journalctl -b -o short-monotonic -u zfs-wipe-home.service
   journalctl -b -o short-monotonic --grep 'sysroot|zfs-wipe'
   ```

   The `Finished …zfs-wipe-home.service` line must precede
   `Mounted /sysroot/home`. If neither line is present at all, the unit was
   never started — that is Trap 1, and it is the answer more often than
   anything else. Add `rd.systemd.log_level=debug` to `boot.kernelParams` for
   one boot if the ordering is not obvious from the timestamps.

   Caveat: on a host whose `/var/log` is itself wiped and not persisted, this
   evidence is destroyed by the next reboot. Persist `/var/log` (or a journal
   directory) before you start debugging boot ordering.

3. **The dataset is genuinely at the snapshot.** Right after boot:

   ```sh
   zfs get -H -o value written rpool/local/home     # bytes changed since @blank
   zfs list -t snapshot -o name,creation rpool/local/home
   ```

   `written` should be small and growing from zero this boot. A `written` of
   several gigabytes moments after boot means the rollback did not happen. The
   snapshot listing should show `@blank` and, if Trap 4 applies to you,
   nothing else — which is the point at which people discover they have been
   destroying their auto-snapshots.

---

## The test

`test.nix` in this directory is a NixOS VM test that runs all three checks
above against a real machine, across a real reboot:

```sh
nix-build test.nix --arg pkgs 'import <nixpkgs> { system = "x86_64-linux"; }'
```

or, from a flake:

```nix
checks.x86_64-linux.zfs-impermanence-rollback =
  pkgs.callPackage inputs.recipes + "/modules/zfs-impermanence-rollback/test.nix" { };
```

It builds a real pool on a scratch disk, boots a specialisation whose root is
`tank/root` with a second `neededForBoot` dataset at `/state` and an unwiped
one at `/persist`, writes a marker into each, reboots, and asserts:

- the marker on the root dataset is gone;
- the marker on the **second `neededForBoot` dataset** is gone, and the dataset
  is empty — this is the Trap 1 assertion, and it fails on its own when only
  that dataset's rollback is disabled while the machine still boots cleanly;
- the marker on `/persist` **survives**, so the two above are not just "the
  disk came up blank";
- inside the initrd, `zfs-wipe-state.service` is `Before=sysroot.mount
  sysroot-state.mount`, both wipes returned `success`, and each wipe's
  `ActiveEnterTimestampMonotonic` precedes its mount unit's
  `InactiveExitTimestampMonotonic` — the ordering as *observed at runtime*, not
  merely as declared.

Plus four eval-time assertions that need no VM: `enforceNeededForBoot` really
sets it, the emitted unit really carries the `sysroot.mount` anchor and the
pool import ordering, and the `neededForBoot` guard rail really fires (and
fires *only* then).

Note the narrow-anchor case: if the module is changed to emit
`Before=sysroot-state.mount` alone, every behavioural assertion above still
passes — the machine wipes correctly and looks perfect. Only the recorded
`Before=` catches it. That is Trap 1 reproduced in miniature, and it is why
that assertion is in the test.

---

## Caveats

- **This module does not create the blank snapshot.** By design: creating it
  from a module means creating it at some arbitrary later moment, from
  whatever state the dataset is in then. See Trap 5.
- **It does not persist anything.** Pair it with
  `nix-community/impermanence`'s `environment.persistence` or your own bind
  mounts. Getting the wipe right and the persistence wrong is worse than not
  wiping.
- **Systemd initrd only.** Asserted. Under scripted stage 1 there is no unit
  ordering to be correct about, and `boot.initrd.postDeviceCommands` is removed
  anyway.
- **`mountPoint = null` is supported but weaker.** The dataset is still wiped,
  still anchored on `sysroot.mount`, but the `neededForBoot` guard rail and the
  device/dataset cross-check cannot run. Use it only for datasets that are not
  in `fileSystems` at all.
- **Nested datasets are not recursive.** zfs-rollback(8): *"The `-rR` options do
  not recursively destroy the child snapshots of a recursive snapshot. Only
  direct snapshots of the specified filesystem are destroyed."* Rolling back
  `rpool/local/home` does nothing to a child dataset such as
  `rpool/local/home/<someone>`. Declare each dataset you want wiped as its own
  entry.
- **Btrfs needs a different implementation.** The equivalent (`btrfs subvolume
  delete` + `snapshot` from a read-only blank, under the top-level `subvolid=5`
  mount) has the same ordering requirement and the same silent-failure shape,
  plus one extra: nested subvolumes created after the fact — by
  `systemd-nspawn`, by container runtimes — must be deleted first or the parent
  `delete` fails. This module is ZFS-only.
- **Version bounds.** Written against nixpkgs `26.11` (`nixos/modules/tasks/
  filesystems.nix`, `.../filesystems/zfs.nix`, `.../system/boot/systemd/
  initrd.nix`), systemd 261, OpenZFS 2.4. The unit-name derivation mirrors
  `getPoolMounts`; if upstream changes how initrd mount units are named, that
  is the one thing here that has to change with it — which is another argument
  for anchoring on `sysroot.mount`, whose name has been stable for the entire
  life of the systemd initrd.

## License

CC0-1.0.
