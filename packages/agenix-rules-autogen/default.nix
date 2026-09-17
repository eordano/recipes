{
  lib,
  writeText,

  self,

  system,

  secretsDir,

  pathPrefix ? "secrets/",

  excludedSubtrees ? [
    "${pathPrefix}generated/"
    "${pathPrefix}per-host/"
  ],
}:

let
  nixosHosts = builtins.attrValues (self.nixosConfigurations or { });
  darwinHosts = builtins.filter (h: h.config.nixpkgs.hostPlatform.system == system) (
    builtins.attrValues (self.darwinConfigurations or { })
  );
  allHosts = nixosHosts ++ darwinHosts;

  cfg0 = (builtins.head allHosts).config.age.rekey;

  isRecipientLine = l: (builtins.match "(age1[0-9a-z]+|ssh-(ed25519|rsa) [^[:space:]]+.*)" l) != null;
  containsPrivateKey =
    text:
    (builtins.match ".*(AGE-SECRET-KEY-|AGE-PLUGIN-).*" (builtins.replaceStrings [ "\n" ] [ " " ] text))
    != null;
  idPubkey =
    idIn:
    let
      rec' =
        if builtins.isAttrs idIn then
          idIn
        else
          {
            identity = idIn;
            pubkey = null;
          };
    in
    if rec'.pubkey != null then
      rec'.pubkey
    else
      let
        text = builtins.readFile rec'.identity;
        lines = lib.splitString "\n" text;
        recipientLine = lib.findFirst (
          l: (builtins.match "#[[:space:]]*[Rr]ecipient:.*" l) != null
        ) null lines;
      in
      if containsPrivateKey text then
        throw ''
          agenix-rules-autogen: identity file ${toString rec'.identity} contains
          private key material (AGE-SECRET-KEY-... / AGE-PLUGIN-...). Reading it at
          eval time would leak the private key into the world-readable Nix store
          via the generated rules.nix. Supply the public recipient instead --
          either the `{ identity = <path>; pubkey = "age1..."; }` attrset form, or
          a path to the matching `.pub` / recipients file.''
      else if recipientLine != null then
        lib.removeSuffix "\r" (
          builtins.head (
            builtins.match "#[[:space:]]*[Rr]ecipient:[[:space:]]*([^[:space:]]+).*" recipientLine
          )
        )
      else
        let
          nonComment = builtins.filter (l: l != "" && !(lib.hasPrefix "#" l)) lines;
          recipients = builtins.filter (l: isRecipientLine (lib.removeSuffix "\r" l)) nonComment;
        in
        if recipients != [ ] then
          lib.removeSuffix "\r" (builtins.head recipients)
        else
          throw ''
            agenix-rules-autogen: cannot parse a public recipient from
            ${toString rec'.identity}. Expected a `# Recipient: age1...` comment
            line or a line containing an `age1...` / `ssh-ed25519` / `ssh-rsa`
            public recipient. If this is a private identity file, supply the
            `{ identity; pubkey = "age1..."; }` attrset form or a `.pub` file.'';

  fromFile = p: lib.removeSuffix "\n" (builtins.readFile p);

  masterPubkeys = (map idPubkey cfg0.masterIdentities) ++ (map fromFile cfg0.extraEncryptionPubkeys);

  fsSecrets = map (n: pathPrefix + n) (
    builtins.filter (n: lib.hasSuffix ".age" n) (builtins.attrNames (builtins.readDir secretsDir))
  );

  extractPath =
    rf:
    let
      s = toString rf;
      m = builtins.match ".*/(${pathPrefix}.*\\.age)" s;
    in
    if m != null then builtins.head m else null;

  configSecretRefs = lib.unique (
    lib.concatMap (
      h:
      builtins.filter (p: p != null) (
        map (s: extractPath s.rekeyFile) (builtins.attrValues (h.config.age.secrets or { }))
      )
    ) allHosts
  );

  isExcluded = p: lib.any (pre: lib.hasPrefix pre p) excludedSubtrees;

  configSecrets = builtins.filter (p: lib.hasPrefix pathPrefix p && !(isExcluded p)) configSecretRefs;

  allSecrets = lib.sort (a: b: a < b) (lib.unique (fsSecrets ++ configSecrets));

  renderList = xs: lib.concatMapStrings (x: "    \"${x}\"\n") xs;

  content = ''
    let
      masterPubkeys = [
    ${renderList masterPubkeys}  ];
      paths = [
    ${renderList allSecrets}  ];
      mkSecret = p: { name = p; value = { publicKeys = masterPubkeys; }; };
    in builtins.listToAttrs (map mkSecret paths)
  '';
in
writeText "rules.nix" content
