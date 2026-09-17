{
  keysDir,

  secretsRoot,

  yubikeyIdentities ? [ ],

  backupIdentity ? null,

  recoveryPubkeys ? [ ],

  perHostSubdir ? "/secrets/per-host",

  generatedSecretsDir ? (secretsRoot + "/secrets/generated"),
}:

name: pubkey: {
  age.rekey =
    (
      if pubkey == null then
        { }
      else
        {
          hostPubkey = pubkey;
        }
    )
    // {
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
                inherit (backupIdentity) pubkey;
              }
            ]
        );

      extraEncryptionPubkeys = map (f: keysDir + "/${f}") recoveryPubkeys;
    };
}
