# installer-iso-secrets-partition

A NixOS installer ISO that auto-joins a mesh VPN and can clone from a private
forge — while the image itself contains **no credentials at all**. Every secret
lives on a separate, labelled partition appended to the USB stick after the
image has been written, and a boot-time oneshot finds it by filesystem label,
mounts it read-only, and gets out of the way.

Both halves ship here: the NixOS module that consumes the partition at boot, and
the flasher that creates it. Either half alone is useless.

## The problem

You want an installer stick you can hand to anyone, boot on any machine, and
have it come up already on your mesh VPN and already able to `git clone` from
your private forge. That means it needs a VPN pre-auth key and an SSH identity
at boot.

The intuitive move is to bake them into the ISO — read the key file at eval
time, or `environment.etc` it in. **Do not.** Three things go wrong, all
permanent:

1. **The image becomes a credential.** Everything an ISO carries lands in
   `/nix/store`, which is world-readable on every machine that ever built or
   substituted it. Anyone who can read the store — or the ISO, or your binary
   cache — has your pre-auth key.
2. **The artifact stops being shareable and cacheable.** A key-free ISO is a
   plain build product: push it to a cache, hand it to a colleague, keep it in
   CI. A key-bearing one is a secret with a `.iso` extension.
3. **Rotation means re-flashing every stick.** The key is welded to the image
   hash. Rotate it and every existing stick is dead; re-flashing a dozen sticks
   with a 1.5 GB image is an afternoon.

## The design

```
    build (pure, cacheable, key-free)          flash (operator's workstation)
  ┌───────────────────────────────┐          ┌──────────────────────────────┐
  │  .#installer-iso  →  *.iso    │  ─dd──▶  │  p1  hybrid ISO9660          │
  └───────────────────────────────┘          │  p2  EFI system partition    │
                                             │  p3  ext4, label INSTALLER-SEC│◀─ age -d
                                             └──────────────────────────────┘   (never
                                                            │                     hits the
                                          boot              │                     store)
                                             ┌──────────────▼───────────────┐
                                             │ installer-secrets-mount.service│
                                             │  poll  blkid -L INSTALLER-SEC │
                                             │  mount ro,nosuid,nodev,…      │
                                             │  Before= the VPN units        │
                                             └──────────────┬───────────────┘
                                                            ▼
                                             tailscaled reads authKeyFile
                                             ssh reads IdentityFile
```

The image is a pure function of your config. The secrets are a property of the
*stick*. Rotating a key is `flash-installer --skip-build /dev/sdb` — 3 seconds,
no rebuild. Losing a stick means revoking one pre-auth key, not re-issuing an
image.

## How to use it

```nix
{ config, ... }:
{
  imports = [ ./installer-iso-secrets-partition ];

  modules.installerSecretsPartition = {
    enable = true;
    label = "INSTALLER-SEC";
    mountPoint = "/run/installer-secrets";

    # logical name -> filename on the partition
    secretFiles = {
      vpnAuthKey = "vpn-auth";
      forgeKey = "forge-id_ed25519";
    };

    # everything that reads a credential must be ordered AFTER the mount
    before = [ "tailscaled.service" ];

    # ssh_config blocks whose identity lives on the partition
    sshHosts = [
      {
        patterns = [ "forge" "forge.example.com" ];
        hostName = "forge.example.com";
        user = "git";
        identityFile = config.modules.installerSecretsPartition.paths.forgeKey;
      }
    ];

    # a real password on the installer accounts (see trap 3)
    password.hashedPassword = "$6$rounds=...$...";

    flasher.ageIdentityFile = "keys/age-identity.txt";
  };

  services.tailscale = {
    enable = true;
    authKeyFile = config.modules.installerSecretsPartition.paths.vpnAuthKey;
  };
}
```

Then, on your workstation:

```sh
nix build .#installer-iso                 # pure, cacheable, key-free
flash-installer /dev/sdb                  # dd + append + decrypt + populate
# on the booted installer:
systemctl status installer-secrets-mount
```

Expose the flasher from your flake rather than shipping it inside the ISO:

```nix
packages.x86_64-linux.flash-installer =
  self.nixosConfigurations.installer.config
    .modules.installerSecretsPartition.flasher.package;
```

## The five traps

### 1. The label is not there when `local-fs.target` is

This is the one that actually bites. The obvious implementation is a oneshot
`After=local-fs.target` that does one `blkid -L`, and it *works on your laptop*.
On real hardware it races: USB enumeration, the SCSI disk probe and udev's
`blkid` scan of the new partition all finish some hundreds of milliseconds after
`local-fs.target` is reached, because that target only covers filesystems in
`fstab` — and this partition deliberately is not in `fstab`.

When the race is lost the unit reports success (it "found nothing"), the VPN
daemon starts, `authKeyFile` does not exist, and **the machine boots fine and
silently never joins the mesh**. You discover it by not finding the host.

So the unit **polls**: `blkid -L <LABEL>` up to `pollAttempts` times with
`pollIntervalSeconds` between tries — 20 × 0.5 s = a 10-second budget by
default, which covers slow USB3 hubs and still fails fast on a stick that
genuinely has no secrets partition. Three more properties matter:

- **`before = [ ... ]`** lists every unit that reads a credential. systemd
  ordering, not `wants`: the mount is not a dependency, it is a *precondition*.
  Getting this list wrong reproduces the exact silent failure above.
- **`ro,nosuid,nodev,uid=0,gid=0,fmask=0177,dmask=0077`** — read-only so a
  booted installer cannot rewrite the stick, `nosuid,nodev` because this is
  removable media someone else may have handled, and the `uid`/`mask` options so
  that even on FAT (which has no unix permissions) the files land as root-only
  `0600` in a `0700` directory.
- **`optional = true` (the default) exits 0 when the label is absent**, so the
  *identical image* still boots as a plain rescue disk. This is why the whole
  scheme costs you nothing: one artifact, two roles.

Upstream has nothing like this. There is no NixOS option, anywhere, for
"credentials that travel next to the image instead of inside it" — the installer
profiles assume either an interactive operator or a fully baked image.

### 2. `sgdisk --new` on a dd'd hybrid ISO silently corrupts the table

GPT keeps a *backup* header and table at the **last sector of the device**.
When you `dd` a 1.5 GB hybrid ISO onto a 32 GB stick, that backup lands
wherever the image ended — a third of the way into the stick — and the primary
header still claims the device is 1.5 GB long. `sgdisk --new` will happily add
your partition and write the backup right back to that stale mid-device offset.
Nothing errors. The firmware, or the next tool that reads the disk, sees an
inconsistent pair and you get a stick that boots on your machine and not on the
next one.

The fix is one flag, run **before** any modification:

```sh
sgdisk --move-second-header /dev/sdb
sgdisk --new="3:-16M:0" --typecode=3:8300 --change-name=3:INSTALLER-SEC /dev/sdb
```

**`move-second-header` appears zero times in nixpkgs.** Verified against
nixpkgs 26.11 (rev `e2587ca`): `grep -rn move-second-header` over the entire
tree returns nothing, and the only four `sgdisk` call sites are
`nixos/lib/make-disk-image.nix:306,324,344,364` — all building images from
scratch at a known size, where the backup header is correct by construction.
Nixpkgs never appends to a dd'd image, so it never had to learn this. You do.

A second, louder failure lives in the same step: an isohybrid image often leaves
an **MBR ("dos") label**, not GPT, whose partition 1 starts at sector 0 and
spans the image with the EFI partition nested inside it. A GPT partition may not
start at sector 0, so `sgdisk --print` exits **2** with `Invalid partition
data!` — and under `set -o pipefail` that kills your whole script at the worst
possible moment, right after the `dd`. So the flasher reads the actual label
type from `sfdisk --list` and appends with the matching tool: `sgdisk` for GPT,
`sfdisk --append` for MBR (which rewrites only the table entries and leaves
partitions 1/2 and the isohybrid boot code untouched).

Losing the GPT partition *name* on the MBR path costs nothing, because the
booted system looks the partition up by **filesystem** label (`blkid -L`), which
`mkfs` sets. The GPT partition name was never load-bearing.

### 3. A real installer password needs priority < 60

`profiles/installation-device.nix` gives both accounts an empty password
(`initialHashedPassword = ""` at lines **45** and **49** of
`nixos/modules/profiles/installation-device.nix`, nixpkgs 26.11), and the rest
of that profile forces its opinions with `lib.mkImageMediaOverride`, which is
**`mkOverride 60`** (`lib/modules.nix:1572`). Setting a password at normal
priority either conflicts or loses, and — because an empty
`initialHashedPassword` is *not* an error — you find out by discovering your
"password-protected" installer lets anyone in.

So define below 60. This module uses `mkOverride 49` (`password.priority`),
which also beats a `mkForce` (priority 50) coming from your own base modules,
and sets both fields together:

```nix
hashedPassword        = mkOverride 49 "$6$…";
initialHashedPassword = mkOverride 49 null;   # or the empty one still applies
```

The module asserts `priority < 60` so this cannot regress silently.

Note the honest limit of this feature: a password *hash* on an installer image
is world-readable in the store, like everything else in the image. It is a
speed bump for the console, not a secret. That is precisely why the VPN key and
the SSH identity are on the partition instead.

### 4. `copytoram`

`copyToRam = true` adds the `copytoram` kernel parameter, so the squashfs is
copied into RAM during boot and **the stick can be pulled out mid-install**.
That matters more than it sounds: an install can take twenty minutes, and the
alternative is a USB stick dangling out of a rack machine that someone will walk
past and knock. It also means you can flash the *next* stick while the first
machine is still installing.

Cost: boot takes longer by roughly image-size ÷ USB read speed, and you need
RAM for the whole image. On a 1.5 GB minimal ISO with a 4 GB machine this is
fine; on a 2 GB desktop ISO and 2 GB of RAM it will not boot.

### 5. The partition node does not exist yet either

Three separate things bite between "the partition table now has a third entry"
and "I can `mkfs` it":

- **Suffix**: `/dev/sdb` → `/dev/sdb3`, but `/dev/nvme0n1` → `/dev/nvme0n1p3`,
  and likewise `mmcblk*` and `loop*` need the `p`. Concatenating blindly either
  formats the wrong node or nothing at all.
- **The kernel has not re-read the table**: `partprobe <device>` after every
  table change.
- **udev has not created the node**: `udevadm settle --timeout=10`, and then a
  **bounded poll** (`[ -b "$node" ]`, 10 × 1 s) anyway, because `settle` returns
  when the *current* queue drains and the partition-scan event may not have been
  queued yet. The flasher fails loudly if the node never appears rather than
  running `mkfs` against a nonexistent path.

The same "settle is a hint, not a guarantee" reasoning is what forces the poll
in trap 1. Removable-media timing is not deterministic anywhere in this recipe.

## What upstream already does — do not duplicate it

**`nix.registry.nixpkgs` and `nixPath` pinning is done for you.**
`nixos/modules/installer/cd-dvd/channel.nix:51` sets `nix.registry.nixpkgs.to`
to the cleaned nixpkgs source bundled in the image, and the same module unpacks
that source as the root channel. That module is imported transitively by
`profiles/installation-device.nix`, i.e. by every `installation-cd-*.nix`.
This recipe deliberately contains no registry or `nixPath` handling; adding
some means you are fighting a module you already imported.

**Do not trust `image.fileName` for the artifact name.** `iso-image.nix` builds
the file as `"${config.image.baseName}.iso"` (line 1042) while
`image.filePath` is `"iso/${config.image.fileName}"` (line 1034). Set only
`fileName` and the advertised path names a file that does not exist. Either
`mkForce` `image.baseName`, or — as the flasher does — glob for whatever single
`*.iso` the derivation produced and never guess.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `label` | `"INSTALLER-SEC"` | **Filesystem** label, found with `blkid -L`. ext4 caps labels at 16 bytes, FAT at 11 — asserted. |
| `mountPoint` | `/run/installer-secrets` | Where it is mounted. Keep it under `/run`. |
| `unitName` | `installer-secrets-mount` | Name of the oneshot (and of its script). Configurable so an existing deployment can adopt this module without renaming its unit. |
| `mountOptions` | `ro,nosuid,nodev,uid=0,gid=0,fmask=0177,dmask=0077` | Joined with commas. See trap 1. |
| `pollAttempts` | `20` | Label lookups before giving up. |
| `pollIntervalSeconds` | `"0.5"` | Passed verbatim to `sleep`. Default budget = 10 s. |
| `optional` | `true` | Exit 0 when the partition is absent, so the same image boots as a rescue disk. |
| `before` | `[ "tailscaled.service" ]` | Units ordered after the mount — every credential consumer. |
| `after` | `[ "local-fs.target" ]` | Ordering of the mount unit itself (a starting gun, not a guarantee). |
| `secretFiles` | `{ }` | Logical name → filename on the partition. |
| `paths` | *(read-only)* | `name → "<mountPoint>/<filename>"`, for consumers to reference. |
| `copyToRam` | `true` | Add the `copytoram` kernel parameter. |
| `sshHosts` | `[ ]` | ssh_config `Host` blocks pinned to an identity on the partition. |
| `strictHostKeyChecking` | `"accept-new"` | For the generated blocks. Set `yes` + a known_hosts file if an active attacker on the install network is in scope. |
| `password.hashedPassword` | `null` | Real hash for the installer accounts. |
| `password.users` | `[ "root" "nixos" ]` | Accounts it applies to. |
| `password.priority` | `49` | Must be `< 60` — asserted. See trap 3. |
| `flasher.enable` | `false` | Put the flasher in `environment.systemPackages`. It belongs on the *workstation*, not in the ISO. |
| `flasher.package` | *(read-only)* | The generated flasher, pre-baked with this module's label/size/secret list. |
| `flasher.name` | `"flash-installer"` | Executable name. |
| `flasher.isoAttr` | `".#installer-iso"` | Flake attribute built when `--iso` is not given. |
| `flasher.partitionSizeMiB` | `16` | Size of the appended partition. |
| `flasher.filesystem` | `"ext4"` | `ext4` (real unix permissions) or `vfat` (readable elsewhere; relies on the mount masks). |
| `flasher.ageIdentityFile` | `""` | Default age identity (`--identity`). |
| `flasher.ageSecretsDir` | `"secrets"` | Directory of `<name>.age` files (`--age-dir`). |

## The flasher

```
flash-installer [OPTIONS] [DEVICE]
```

Order of operations is chosen so that failures are cheap:

1. **Build** (or accept `--iso`), globbing the produced `*.iso`.
2. **Pick and vet the device.** Refuses `/dev/nvme*` outright and refuses the
   device backing `/`. Asks for a typed `yes` unless `--yes`.
3. **Decrypt the secrets into a `mktemp -d`, before touching the disk.** A
   missing `.age` file, a wrong identity or an unplugged hardware token then
   fails while the stick is still intact. Doing this after the `dd` means an
   expired token leaves you with a half-provisioned stick.
4. `dd`, `partprobe`, `settle`.
5. Append the partition (trap 2), settle, poll for the node (trap 5), `mkfs`.
6. Mount, `install -m 0400 -o 0 -g 0` each secret, `sync`, unmount.

`nix`, `sudo` and `age`/`rage` are intentionally **not** in `runtimeInputs`:
they come from the operator's own PATH, so the flasher uses the same Nix daemon,
the same sudo policy and the same (possibly hardware-backed) age implementation
the operator already trusts. `--plaintext-dir DIR` skips decryption entirely if
your secrets come from somewhere else.

## Caveats

- **The partition is not encrypted.** Its threat model is "the image is public,
  the stick is not". Anyone holding the stick holds the keys — treat it like a
  key on a lanyard, keep the secrets low-privilege (a single-use, expiring VPN
  pre-auth key; a deploy key with read-only access to the repos an installer
  needs), and revoke on loss. If you need the stick itself to be safe when lost,
  put LUKS on that partition and unlock it from the console; the module's
  polling/ordering logic is unchanged, only `mountOptions` and the flasher's
  `mkfs` step move.
- `strictHostKeyChecking = "accept-new"` trusts the forge host key seen on the
  first connection. That is what makes an unattended installer usable and is a
  real (if narrow) TOFU window on an untrusted install network.
- The module only *orders* itself before the VPN units; it does not configure
  the VPN. That is deliberate — it works the same with tailscale, netbird,
  nebula or a WireGuard unit, as long as you list the right units in `before`.
- The flasher shells out to `sfdisk`/`sgdisk`/`mkfs` and needs root. It is an
  operator tool, not something to run from CI.
