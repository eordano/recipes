# Per-Host agenix-rekey Configuration with YubiKey Masters and Encrypted Backup

A curried [agenix-rekey](https://github.com/oddlama/agenix-rekey) module
fragment. You apply it once with your fleet-wide key settings, then call the
result per host as `ageWith name pubkey` to produce that host's `age.rekey`
block. It encodes four things that are easy to get subtly wrong.

## The problem

With agenix-rekey, secrets are stored encrypted to a set of *master
identities* (the keys a human uses to edit/rekey) and rekeyed per host to each
host's own key. When your master identities are hardware YubiKeys, you also
want:

- an **offline backup identity** in case the YubiKeys are lost — but the backup
  identity itself should be encrypted at rest, and
- **recovery recipients** so every secret can also be opened another way,

...without pinning a recipient a host can't yet use during bootstrap. Those
requirements collide in a few non-obvious ways.

## The key insights / traps

1. **Inline the encrypted backup identity's pubkey.**
   A normal master identity is a plaintext `.pub` file, so agenix reads the
   recipient's public key straight from it. But if you keep the backup identity
   *encrypted at rest* (an `age`-encrypted `.age` file), agenix can't read a
   pubkey out of it without decrypting it first — which defeats the point of an
   offline, seldom-unlocked backup. The fix is to give the pubkey **inline**
   next to the encrypted identity:

   ```nix
   {
     identity = keysDir + "/age-offline-backup-identity.age";
     pubkey   = "age1...";   # stated explicitly, no decryption needed
   }
   ```

   Now agenix can select the backup as a recipient at rekey time while the
   private identity stays sealed.

2. **Omit `hostPubkey` for hosts that can't decrypt yet.**
   During install / first boot, a host has no age key of its own. If you pin a
   `hostPubkey` for it anyway, rekey encrypts secrets to a recipient that host
   cannot open — a footgun that "works" until you actually try to boot it. Pass
   `pubkey = null` for such hosts and the whole `hostPubkey` attribute is left
   out; the host still gets secrets via the master + recovery recipients until
   it has a key. Fill in the real pubkey once the host can decrypt.

3. **`extraEncryptionPubkeys` are recovery recipients on *every* secret.**
   These are added on top of the masters, so any secret can also be opened with,
   e.g., a YubiKey SSH recipient or an offline root-recovery key. This is your
   break-glass path if the primary identities are unavailable.

4. **`hostPubkey` accepts an age *or* ssh public key.**
   Pass the host's own key as `age1...`, as `ssh-ed25519 AAAA...`, or as a Nix
   path to a file holding one — agenix-rekey takes any of those. Just be
   consistent per host.

## Usage

Partially apply once with your key settings, then call per host:

```nix
let
  ageWith = import ./agenix-rekey-yubikey-per-host {
    keysDir     = ../keys;   # dir with the .pub / .age files (a Nix path)
    secretsRoot = ../.;      # repo root containing secrets/ (a Nix path)

    yubikeyIdentities = [
      "age-yubikey-primary-identity.pub"
      "age-yubikey-backup-identity.pub"
    ];

    backupIdentity = {
      identity = "age-offline-backup-identity.age";
      pubkey   = "age1ExampleReplaceWithYourBackupPubkey00000000000000000000";
    };

    recoveryPubkeys = [
      "age-yubikey-ssh.pub"
      "root-backup.pub"
    ];
  };
in
{
  # a normal host with its own key (age or ssh form both work):
  "your-host" = ageWith "your-host" "ssh-ed25519 AAAA...";

  # a host that can't decrypt yet (installer / bootstrap image):
  "installer" = ageWith "installer" null;
}
```

Import each `ageWith name pubkey` result as a NixOS module for that host.

### Options

| option | default | meaning |
| --- | --- | --- |
| `keysDir` | — | Nix path to the directory holding all master/recovery key files. |
| `secretsRoot` | — | Nix path to the repo root under which per-host ciphertext lives. |
| `yubikeyIdentities` | `[]` | Plaintext `.pub` master identity filenames (relative to `keysDir`). |
| `backupIdentity` | `null` | `{ identity; pubkey; }` for an *encrypted* backup identity with its pubkey inlined. |
| `recoveryPubkeys` | `[]` | Extra recipient `.pub` filenames added to every secret. |
| `perHostSubdir` | `"/secrets/per-host"` | Sub-path (under `secretsRoot`) for per-host rekeyed ciphertext; `<name>` is appended. |
| `generatedSecretsDir` | `secretsRoot + "/secrets/generated"` | Where generated secrets are written. |

## Caveats

- `storageMode = "local"` keeps rekeyed ciphertexts **in the repo**
  (`secrets/per-host/<name>`), not out of tree. That directory must be
  writable in your working tree when you rekey.
- Everything except `hostPubkey` is fleet-wide and identical across hosts — the
  per-host application only decides whether to pin a `hostPubkey`.
- The inlined `backupIdentity.pubkey` must actually match the encrypted
  identity, since nothing verifies it against the sealed file at eval time. A
  mismatch means secrets get encrypted to a key you can't recover with.
