# zfs-native-encryption-keys

Unlock **ZFS native encryption** on non-root pools from a runtime key file
(agenix / sops-nix / systemd-creds / a ramfs drop), with the ordering that makes
it safe: the key loads after the pool is imported, the datasets mount after the
key loads, and your services run after the mounts — or not at all.

Ships with a NixOS VM test (`test.nix`) that boots an encrypted pool, proves the
unlock happened on that boot, proves the data is genuinely inaccessible without
the key, reboots, and asserts the fail-closed path on both key-delivery
mechanisms. See [Testing](#testing).

## Why this exists — what nixpkgs does not do

nixpkgs knows exactly one way to load a ZFS key: as a **side effect of importing
the pool**, from whatever `keylocation` property the dataset happens to carry on
disk. See `nixos/modules/tasks/filesystems/zfs.nix`:

| Upstream | Where | What it means for you |
| --- | --- | --- |
| `createImportService` embeds the key-loading loop in `zfs-import-<pool>.service` | `zfs.nix:152`, loop at `:214-238` | There is no unit whose job is "the keys are loaded". You cannot order anything against key availability, only against *import*. |
| Same service is generated for non-root pools | `zfs.nix:942` (`map createImportService' dataPools`) | A data pool's keys are handled in a unit with `DefaultDependencies=no` that runs before almost everything — including anything that produces your key at runtime. |
| `boot.zfs.requestEncryptionCredentials` defaults to `true` | `zfs.nix:385` | "Prompt for **every** encrypted dataset on import", data pools included. |
| `prompt` keylocation → `systemd-ask-password --timeout=${boot.zfs.passwordTimeout}` | `zfs.nix:227`, option at `:402` | `passwordTimeout` **defaults to 0, which waits forever** — on a headless box that is a silent, permanent stall of the pool's mount units, not a failure. |
| The key path is a **dataset property**, not NixOS config | on disk | Your config cannot say where the key is. Whatever you set at `zpool create` time is what boot uses, forever, until someone runs `zfs set` by hand. |

This module adds the missing piece: a named, orderable
`zfs-load-key-<pool>.service` that loads the key from a path **declared in your
NixOS config**, using `zfs load-key -L <location>` to override the on-disk
`keylocation` for that one call.

## Usage

```nix
{
  imports = [ ./zfs-native-encryption-keys ];

  services.zfsNativeKeys = {
    enable = true;

    # Stop nixpkgs' import units from also trying to unlock things.
    # Here: only the root pool is handled by the boot prompt.
    restrictImportCredentialsTo = [ "rpool" ];

    # Every dataset of this pool uses mountpoint=legacy and is declared below,
    # so the blanket `zfs mount -a` has nothing to do but race us.
    disableZfsMountService = true;

    pools.tank = {
      datasets = [ "tank/archive" "tank/media" ];   # encryption ROOTS only
      keyFile = config.age.secrets.tank-key.path;   # a RUNTIME path, not a store path

      mounts = {
        "/tank/archive" = "tank/archive";
        "/tank/media"   = "tank/media";
      };

      # Hard dependency: these do not start if the key never loads.
      requiredBy = [ "nginx.service" ];
      # Ordering only: this starts anyway, just not before us.
      before = [ "docker.service" ];
    };
  };
}
```

Generated for the example above:

```ini
# zfs-load-key-tank.service
After=zfs-import-tank.service
Before=docker.service nginx.service
Type=oneshot
RemainAfterExit=true
LoadCredential=zfs-key:/run/agenix/tank-key
```

```nix
# fileSystems."/tank/media".options
[ "zfsutil" "x-systemd.requires=zfs-load-key-tank.service"
            "x-systemd.after=zfs-load-key-tank.service" ]
```

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `package` | `config.boot.zfs.package` | ZFS userland for the units. Keeps the CLI from drifting from the loaded kernel module. |
| `disableZfsMountService` | `false` | Disable `zfs-mount.service` (`zfs mount -a`). |
| `restrictImportCredentialsTo` | `null` | Pin `boot.zfs.requestEncryptionCredentials` to a dataset list (usually just the root pool). `null` leaves it alone. |
| `pools.<pool>.datasets` | `[ "<pool>" ]` | Encryption roots to unlock. |
| `pools.<pool>.keyFile` | — (required) | Runtime path to the key/passphrase. A `str`, not a `path`, on purpose. |
| `pools.<pool>.useCredential` | `true` | Pass the key via systemd `LoadCredential=` instead of reading the path directly. |
| `pools.<pool>.preflight` | `true` | With `useCredential = false`, check readability first and exit with a clear message. |
| `pools.<pool>.after` | `[ "zfs-import-<pool>.service" ]` | What the unit runs after. |
| `pools.<pool>.before` / `.requiredBy` | `[ ]` | Ordering-only vs hard-dependency consumers. |
| `pools.<pool>.mounts` | `{ }` | mountpoint → dataset; generates `fileSystems` entries wired to the key unit. |
| `pools.<pool>.mountOptions` | `[ "zfsutil" ]` | Base options for those entries. |
| `pools.<pool>.mountAll` | `false` | Append `zfs mount -a` for ZFS-managed (non-legacy) mountpoints. |
| `pools.<pool>.unitName` / `.description` / `.wantedBy` | derived | Cosmetics / boot wiring. |

## The traps

### 1. `grep -q available` also matches `unavailable`

This is the bug that motivated the recipe. The obvious hand-rolled unit is:

```sh
# WRONG — do not copy this
if ! zfs get -H -o value keystatus "$ds" | grep -q "available"; then
  zfs load-key -L "file://$KEY" "$ds"
else
  echo "key already loaded for $ds"
fi
```

`keystatus` has exactly two values, `available` and `unavailable`, and
`unavailable` **contains** `available` as a substring. So the locked case —
the only case the unit exists for — matches, `!` inverts it, and the script
takes the "already loaded" branch and **never loads the key**. It exits 0, the
unit goes green, the journal says "key already loaded", and the pool stays
locked. Nothing fails. A unit like that can sit in a fleet for years looking
healthy because the pool is *actually* being unlocked by something else
(upstream's import service, or a human), and the day that something else stops,
the "working" unit does not save you.

This module uses an exact match and treats anything that is neither
`available` nor `unavailable` (`-` for an unencrypted dataset, empty for a
missing one) as a hard error:

```sh
status=$(zfs get -H -o value keystatus "$dataset" || true)
case "$status" in
  available)   echo "key already loaded for $dataset"; continue ;;
  unavailable) zfs load-key -L "file://…" "$dataset" ;;
  *)           echo "unexpected keystatus '$status'" >&2; exit 1 ;;
esac
```

If you ever write the `grep` form anyway, `grep -qx available` (whole-line) is
correct; plain `grep -q available` is not.

### 2. Fail closed, never hang — and never `ConditionPathExists`

Three ways a missing key can end, only one of which is acceptable:

* **Hang (upstream default).** `keylocation=prompt` on a data pool + the default
  `boot.zfs.requestEncryptionCredentials = true` means the pool's import unit
  runs `systemd-ask-password --timeout=0` (`zfs.nix:227`, `passwordTimeout`
  default 0 = *wait forever*, `zfs.nix:402`). On a headless machine that request
  is never answered, the import unit never finishes, and every mount ordered
  after it waits with it. Boot "succeeds"; the data is simply never there. Set
  `restrictImportCredentialsTo` so upstream stops trying.
* **Fail open (the tempting fix).** Guarding the key unit with
  `unitConfig.ConditionPathExists = keyFile` looks defensive. It is the
  opposite: a failed `Condition*` marks a unit **successfully skipped**, so
  `Requires=` on it is satisfied, consumers start, and they write into the
  *bare mountpoint directory* — see trap 3. Never gate a key-load unit on a
  Condition.
* **Fail closed (this module).** `LoadCredential=` makes systemd itself refuse
  to start the unit when the source is missing or unreadable; the unit goes to
  `failed` in milliseconds, `Requires=` consumers do not start, and mount units
  wired with `x-systemd.requires=` do not attempt the mount. With
  `useCredential = false` an explicit readability preflight does the same job
  with a legible message instead of `Key load error: Failed to open key material
  file`.

### 3. What "not ordered" actually costs you: the shadowed mountpoint

If a service starts before `/tank/media` is mounted, it does not fail. It
happily creates `/tank/media/...` **on the root dataset**, underneath the
future mountpoint. When the mount finally lands, those files vanish from view —
still on disk, still consuming root-pool space, invisible to every tool that
looks at the mounted path. You discover it months later as an inexplicably full
root pool, and `du /tank` will not show it (you have to unmount to see it).

The chain that prevents it, all of it generated by this module:

```
zfs-import-tank.service        (nixpkgs)
      ↓ After=
zfs-load-key-tank.service      (this module)
      ↓ x-systemd.requires= / x-systemd.after=
tank-media.mount               (generated from `mounts`)
      ↓ RequiresMountsFor= / Requires= + Before=
your service
```

Anything that already declares `RequiresMountsFor=/tank/media` (or has a
`WorkingDirectory=` there) joins the chain automatically. For everything else,
list it in `requiredBy` (hard) or `before` (ordering only).

### 4. `zfs mount -a` is not on your side

`zfs-mount.service` runs a blanket `zfs mount -a`. It races your declared mount
units, and it exits non-zero the moment any dataset's key is not loaded — so on
a host with a key-file pool it is either a no-op or a permanently red unit.
When every dataset you care about is `mountpoint=legacy` and declared in
`mounts`, set `disableZfsMountService = true`.

Related, if this pool is also your root: an all-ZFS root has no single block
device to dissect, and since nixpkgs #441777 `systemd-gpt-auto-generator`'s
failure is fatal (drops to rescue). Mask it with
`systemd.generators.systemd-gpt-auto-generator = "/dev/null"`.

### 5. `-L` overrides `keylocation` without rewriting it

`zfs load-key -L file:///run/secrets/tank.key tank` uses that location **for
this call only**. The dataset property is untouched — it can stay `prompt`
forever, meaning nothing written to the disk points at where the key lives. The
usual bootstrap (and what disko's `postCreateHook` does) is:

```nix
rootFsOptions = {
  encryption = "aes-256-gcm";
  keyformat = "passphrase";
  keylocation = "file:///tmp/secret.key";   # only during `zpool create`
};
postCreateHook = ''zfs set keylocation="prompt" zroot'';
```

The test asserts this: after unlocking from a file,
`zfs get -H -o value keylocation testpool` still reads `prompt`.

Conversely, if you *do* leave `keylocation=file:///run/secrets/tank.key` on
disk, upstream's import service will load the key for you — and this module's
unit becomes a no-op that reports "key already loaded". That is a legitimate
configuration; just know which of the two you are running, because they fail
very differently.

### 6. One passphrase for a mirror — the encryption-root rule

`zfs load-key` operates on **encryption roots**, not disks and not datasets.
A pool created with `zpool create -O encryption=aes-256-gcm` has exactly one
encryption root (the pool), which every child inherits, no matter how many disks
the vdev has. A two-disk mirror therefore takes **one** passphrase entry for the
whole pool.

Contrast LUKS-under-ZFS: one dm-crypt mapper per member disk, so a two-disk
mirror produces **two** independent passphrase requests. That is a real,
reproduced boot stall — remote unlock answers the *pending* request and exits
(see `remote-luks-unlock`, `systemd-tty-ask-password-agent --query`), the second
request appears afterwards, nobody answers it, and the boot sits there. The VM
test that covers the native mirror asserts exactly this: a single
`send_chars("…\n")` reaches `multi-user.target`.

If you actually want per-dataset keys, create the children with their own
`-o encryption` / `-o keyformat` so each becomes its own encryption root, then
list them all in `datasets`. `zfs load-key` on an inheriting child fails with
`Keys must be loaded for encryption root`. Check with
`zfs get -r encryptionroot <pool>`.

Two more consequences of encryption living above the vdev layer:

* **Mirrors encrypt once.** ZFS native encrypts in the ZIO pipeline and writes
  the same ciphertext to both members. LUKS encrypts per device, so an n-way
  mirror pays n× the crypto cost on every write.
* **`zfs send --raw` works.** You can replicate encrypted datasets to a backup
  host that never holds the key. LUKS gives you nothing comparable.

## ZFS native vs LUKS — which to use

This collection also ships `remote-luks-unlock`. They solve different halves of
the problem and compose:

| | ZFS native (`zfs load-key`) | LUKS (`cryptsetup`) |
| --- | --- | --- |
| Granularity | per dataset (encryption root) | per block device |
| Mirror of N disks | 1 encryption root → **1** passphrase | N mappers → **N** passphrases |
| Crypto cost on a mirror | once per write | once per write **per disk** |
| Encrypted replication | `zfs send --raw`, key never leaves the source | not available |
| Hides pool layout / dataset names / sizes | **no** (metadata is plaintext) | yes |
| Works for non-ZFS filesystems | no | yes |
| Per-dataset key rotation | `zfs change-key` (re-wraps the master key; no data rewrite) | `cryptsetup luksChangeKey` per device |

Rules of thumb:

* **Root pool, headless machine** → ZFS native with `keylocation=prompt`, plus
  `remote-luks-unlock` to answer that prompt over initrd SSH. Despite the name
  it works verbatim for ZFS: nixpkgs asks via `systemd-ask-password`
  (`zfs.nix:227`), which is the same agent `--query` answers. The same
  three-attempt lockout applies on both sides — nixpkgs retries the ZFS prompt
  `tries=3` (`zfs.nix:224`), `systemd-cryptsetup` also gives up after 3 — after
  which only a reboot gets you a fresh prompt.
* **Data pool that must come up unattended** → this module, with the key from a
  secret manager. No prompt, fail-closed, orderable.
* **Non-ZFS filesystem, or you must hide that the data exists at all** → LUKS.

## Testing

`test.nix` is a NixOS VM test of the module itself. Run it standalone:

```sh
nix-build test.nix --arg pkgs 'import <nixpkgs> { system = "x86_64-linux"; }'
```

or from a flake: `pkgs.callPackage ./modules/zfs-native-encryption-keys/test.nix { }`.

It imports the module directly (`./default.nix`) — no adapter, no
`colmenaBasePath` — plus the `secretsStub` fixture from
[`lib/nixos-test-topology`](../../lib/nixos-test-topology), which materialises
the key at the *real* secret provider's path convention
(`config.age.secrets.<name>.path`). If you vendor this recipe on its own, either
copy that lib too or replace the stub with an `environment.etc` entry.
`mkTopology` is deliberately **not** used: the two nodes never exchange a
packet, so there is no address assignment to take away from the framework.

It creates `aes-256-gcm` pools on scratch disks, flips `keylocation` to
`prompt`, **exports and re-imports with `-N`** so the key is genuinely
unavailable, and then asserts that:

1. the unit unlocked the pool **on that boot** — the journal must show
   `loading key for …` and must *not* show `key already loaded`. This is the
   assertion that makes the rest mean anything: `zpool create` leaves the key
   loaded, so a test that skips the export/import step is green against a module
   that does nothing at all;
2. the unlock came from the runtime key file even though the on-disk
   `keylocation` is `prompt`, and `-L` did not rewrite that property;
3. the datasets are actually mounted, writable, and readable back;
4. the generated `.mount` unit for `mounts` carries `Requires=` + `After=` the
   key unit and mounts the dataset once the key is loaded (see trap 7 below for
   how the entry is smuggled past `qemu-vm.nix`);
5. `requiredBy` consumers get `Requires=` + `After=` and do run on the happy
   path;
6. `disableZfsMountService` masks `zfs-mount.service`, and `mountAll` mounts the
   ZFS-managed datasets;
7. **locking is real**: unmount + `zfs unload-key -a` mid-test makes the data
   inaccessible, `zfs mount -a` cannot bring it back, and the declared mount
   refuses — then restarting the key unit *alone* restores everything. Without
   this control, "keystatus available" is just a string;
8. after a full `shutdown()` / `start()` the pool comes back locked and is
   unlocked again, with the marker files intact;
9. **fail closed on both key-delivery paths**, on a machine where the pools
   exist and are imported and only the key files are missing — so the failure
   cannot be blamed on a missing pool:
   * `useCredential = true` → systemd refuses to start the unit
     (`243/CREDENTIALS`);
   * `useCredential = false` → the `preflight` check exits non-zero with its
     own message;
   * in both cases the unit ends up `failed` with `Result=exit-code` and
     `ConditionResult=yes` — **not** "successfully skipped", which is what the
     tempting `ConditionPathExists` fix produces and which is fail-OPEN;
   * the datasets stay `unavailable`, the declared mount refuses to mount, the
     `requiredBy` consumers never run (asserted by a marker file they would have
     created), and the machine still reaches `multi-user.target` instead of
     hanging on a prompt nobody can answer.

### The test has been seen to fail

Assertions nobody has watched fail are claims, not evidence. Three mutations
were applied to `default.nix` and the test was rebuilt each time:

| mutation | result |
| --- | --- |
| drop the `-L <keyfile>` override, so `load-key` uses the stored `keylocation=prompt` | FAIL — `unit "zfs-load-key-testpool.service" reached state "failed"` in subtest 1 |
| add `unitConfig.ConditionPathExists = keyFile` (the fail-OPEN trap the `preflight` docs warn about) | FAIL — `systemctl is-failed …` returns `inactive`, i.e. the unit was *successfully skipped* |
| stop propagating `requiredBy` to the generated unit | FAIL — `systemctl show -p Requires <consumer>` no longer names the key unit |

Restoring the module produced a byte-identical test derivation and a green run.

### Trap 7 (found by writing this test): a VM test cannot see your `fileSystems`

`nixos/modules/virtualisation/qemu-vm.nix` sets
`fileSystems = mkVMOverride config.virtualisation.fileSystems`, and
`mkVMOverride` (priority 10) beats `mkForce`. So **every `fileSystems` entry a
module declares silently disappears inside a `nixosTest`** — the entry is not in
the guest's `/etc/fstab`, `systemd-fstab-generator` never makes a `.mount` unit,
and `systemctl show -p Requires <x>.mount` reports `LoadState=not-found` with
empty properties. An assertion written against it fails in a way that looks like
the module is broken when it is not.

The fix used here has two halves. First, evaluate the module in a **plain,
non-VM evaluation** (`nixos/lib/eval-config.nix` with just the module) inside
`test.nix`'s `let` block and `assert` on the generated entry, so the test
derivation refuses to build if the options change. Second — and this is what
gives the feature real runtime coverage — feed that *same generated value* back
into the VM through `virtualisation.fileSystems`, which is the option
`qemu-vm.nix` overrides *from*. The guest then builds a genuine `.mount` unit
out of the module's own output, and the test can assert on its `Requires=` /
`After=` and on whether it actually mounts. Nothing is re-typed by hand.

Three smaller gotchas from the same sessions, in case you extend the test:

* `zfsutil` and `mountpoint=legacy` are mutually exclusive. `mount.zfs -o
  zfsutil` delegates to `zfs mount`, which refuses a legacy dataset outright
  (`filesystem '…' cannot be mounted using 'zfs mount'`). Since `mounts`
  defaults to `zfsutil`, a test dataset must carry a real `mountpoint=` — use
  `canmount=noauto` to keep `zfs mount -a` from racing the `.mount` unit for it.
* Declaring a pool's dataset in `fileSystems` makes nixpkgs generate
  `zfs-import-<pool>.service` for it, and `boot.zfs.requestEncryptionCredentials`
  defaults to `true` — i.e. a `systemd-ask-password` in front of a
  `keylocation=prompt` dataset, which hangs the VM. Set
  `restrictImportCredentialsTo = [ ]` (or a root-pool-only list) on the node.

* The test driver runs commands under `set -o pipefail`, and
  `systemctl is-enabled` **exits non-zero for a masked unit**. So
  `systemctl is-enabled zfs-mount.service | grep -qx masked` fails even when the
  output is exactly `masked`. Use
  `test "$(systemctl is-enabled … || true)" = masked`.
* `zfs get -H -o value keystatus` needs `grep -qx`, not `grep -q`, for the same
  reason as trap 1 — a test written with `grep -q available` passes against a
  locked pool.

## Notes and caveats

* **Key material.** `keyFile` is a `str`, not a `path`, so nobody can
  accidentally copy the key into the world-readable Nix store. For
  `keyformat=passphrase` the file must hold 8–512 characters; a stray trailing
  newline is *not* stripped by every tool in the chain — generate it with
  `printf` or `tr -d '\n'`, not `echo`.
* **Rotation.** `zfs change-key -o keylocation=… <encryption root>` re-wraps the
  master key; no data is rewritten and it is instant. But an old key plus an old
  `zfs send --raw` backup still decrypts that old data — rotation limits future
  exposure, not past.
* **Metadata is not secret.** Dataset names, snapshot names, sizes, and most
  properties are readable on an unmounted, locked pool. If the *existence* of
  the data is the secret, native encryption is the wrong tool.
* **Version bounds.** Developed against OpenZFS 2.4.x and systemd 261 on
  nixpkgs 26.11 (`unstable`). `LoadCredential=` needs systemd ≥ 247. Native
  encryption has had genuine raw-send/receive corruption bugs in its history;
  stay on OpenZFS ≥ 2.2 and scrub after any raw-receive-based restore.
* **The unit is idempotent.** `RemainAfterExit=true` plus the `keystatus` check
  means a `nixos-rebuild switch` restart re-runs it harmlessly. To force a
  reload after rotating the key on disk: `zfs unload-key <ds>` (all datasets
  unmounted first), then `systemctl restart zfs-load-key-<pool>`.
