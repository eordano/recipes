# agenix-rekey per-host wiring: YubiKey master identities + an encrypted
# backup identity + extra recovery recipients, with a bootstrap escape hatch.
#
# This is a *curried* module fragment. You partially apply it once with your
# fleet-wide key settings, then call the result per host as `ageWith name pubkey`
# to produce that host's `age.rekey` config. See README.md for the "why".
#
# Usage (in your flake / lib):
#
#   ageWith = import ./agenix-rekey-yubikey-per-host {
#     keysDir          = ../keys;            # dir holding the .pub / .age files
#     secretsRoot      = ../.;               # repo root that contains secrets/
#     yubikeyIdentities = [                   # master YubiKey age recipients
#       "age-yubikey-primary-identity.pub"
#       "age-yubikey-backup-identity.pub"
#     ];
#     backupIdentity = {                      # an *encrypted* offline identity
#       identity = "age-offline-backup-identity.age";
#       # its age pubkey, inlined so agenix can pick it as a recipient
#       # WITHOUT decrypting the identity first (see README):
#       pubkey   = "age1ExampleReplaceWithYourBackupPubkey00000000000000000000";
#     };
#     recoveryPubkeys = [                     # extra recipients on EVERY secret
#       "age-yubikey-ssh.pub"
#       "root-backup.pub"
#     ];
#   };
#
#   # then, per host:
#   #   (ageWith "your-host" hostAgePubkey)   -> imported as a NixOS module
#   #   (ageWith "installer" null)            -> bootstrap host, no hostPubkey
#
# All path-like inputs (keysDir, secretsRoot) should be Nix paths so the files
# are captured in the store. Filenames are strings resolved against keysDir.
{
  # Directory containing all master/recovery key material (.pub and .age).
  keysDir,

  # Repo root under which per-host ciphertext + generated secrets live.
  # `secretsRoot + "/secrets/per-host/<name>"` and
  # `secretsRoot + "/secrets/generated"` must be writable in your tree.
  secretsRoot,

  # Master YubiKey age identities (public-key files). Filenames relative to
  # keysDir. These are the hardware keys that can decrypt at edit/rekey time.
  yubikeyIdentities ? [ ],

  # An offline backup identity that is itself age-encrypted. Because agenix
  # cannot read the pubkey out of an encrypted identity, you inline it here.
  # Set to null if you don't use an encrypted backup identity.
  #   { identity = "<file under keysDir>.age"; pubkey = "age1..."; }
  backupIdentity ? null,

  # Extra recipients that EVERY secret is additionally encrypted to, so you
  # can recover if the primary/YubiKey identities are unavailable. Filenames
  # relative to keysDir.
  recoveryPubkeys ? [ ],

  # Sub-path (relative to secretsRoot) for per-host rekeyed ciphertext.
  # `<name>` is appended. Kept in-repo by default.
  perHostSubdir ? "/secrets/per-host",

  # Path to the directory where generated secrets are written.
  generatedSecretsDir ? (secretsRoot + "/secrets/generated"),
}:

# Per-host application. `name` is the host name; `pubkey` is the host's own
# age public key, or `null` for a host that cannot decrypt yet (installer /
# bootstrap image) — in which case hostPubkey is omitted entirely.
name: pubkey: {
  age.rekey =
    (
      if pubkey == null then
        { }
      else
        {
          # The host's own public key. agenix-rekey accepts an age pubkey
          # ("age1..."), an ssh pubkey ("ssh-ed25519 AAAA..."), or a Nix path
          # to a file containing one. Pass whichever form you keep for the host.
          hostPubkey = pubkey;
        }
    )
    // {
      # Keep rekeyed ciphertexts in the repo, not out of tree.
      storageMode = "local";
      localStorageDir = secretsRoot + (perHostSubdir + "/${name}");
      inherit generatedSecretsDir;

      masterIdentities =
        (map (f: keysDir + "/${f}") yubikeyIdentities)
        ++ (
          if backupIdentity == null then
            [ ]
          else
            [
              {
                identity = keysDir + "/${backupIdentity.identity}";
                # Inlined pubkey: lets agenix select this as a recipient
                # without first decrypting the (encrypted) identity file.
                pubkey = backupIdentity.pubkey;
              }
            ]
        );

      # Every secret is ALSO encrypted to these — recovery recipients.
      extraEncryptionPubkeys = map (f: keysDir + "/${f}") recoveryPubkeys;
    };
}
