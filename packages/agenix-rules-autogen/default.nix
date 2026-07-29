# agenix-rules-autogen
#
# Generate agenix's recipient list (the classic `secrets/rules.nix`) instead of
# hand-maintaining it. The generated file maps every canonical `secrets/*.age`
# to the set of "master" recipients allowed to decrypt and re-encrypt it when
# editing plaintext with `agenix -e` / an `agenix-edit` wrapper.
#
# The path list is the UNION of:
#   1. every `*.age` file physically present in the secrets directory, and
#   2. every `age.secrets.<name>.rekeyFile` referenced by ANY host config,
# minus a configurable set of excluded subtrees (see `excludedSubtrees`).
# The recipient list is DERIVED from `age.rekey.masterIdentities` +
# `age.rekey.extraEncryptionPubkeys` of the first host, so it is never typed by
# hand either.
#
# Pair this with a CI freshness check (regenerate-and-diff) so drift fails the
# build — an example check is shown at the bottom of the README.
#
# HARD DEPENDENCY: this reads `config.age.rekey.*`, which is provided by the
# agenix-rekey NixOS/nix-darwin module + overlay
# (https://github.com/oddlama/agenix-rekey). Import its overlay into the
# `pkgs` that instantiate your host configurations, or the `age.rekey` option
# tree will not exist and evaluation will fail.
#
# callPackage-style. Typical wiring:
#
#   agenix-rules-nix = pkgs.callPackage ./agenix-rules-autogen {
#     inherit self system;
#     secretsDir = ./secrets;
#     # excludedSubtrees = [ "secrets/generated/" "secrets/per-host/" ];
#   };
#
# Then install the built file into your tree:
#
#   install -m 644 ${agenix-rules-nix} "$root/secrets/rules.nix"

{
  lib,
  writeText,

  # The flake `self`, so we can read `self.nixosConfigurations` /
  # `self.darwinConfigurations`.
  self,

  # The system double being evaluated (e.g. "x86_64-linux"). Used to keep only
  # the darwin hosts that match, so a linux evaluation does not try to read
  # darwin-only identity files and vice versa.
  system,

  # Path to the directory that holds the canonical `*.age` ciphertext files
  # (typically `./secrets`).
  secretsDir,

  # Path prefix each emitted entry carries, and the prefix `rekeyFile`
  # references are matched against. Almost always "secrets/".
  pathPrefix ? "secrets/",

  # rekeyFile references whose path starts with any of these prefixes are
  # dropped from the union. These are the agenix-rekey-managed derived trees:
  # the per-host re-encrypted copies and any generator scratch output. They are
  # NOT source secrets and must not appear in the master recipient list. Adjust
  # to match your own directory conventions.
  excludedSubtrees ? [
    "${pathPrefix}generated/"
    "${pathPrefix}per-host/"
  ],
}:

let
  # ---- Collect every host config across both NixOS and nix-darwin ----------
  nixosHosts = builtins.attrValues (self.nixosConfigurations or { });
  darwinHosts = builtins.filter (h: h.config.nixpkgs.hostPlatform.system == system) (
    builtins.attrValues (self.darwinConfigurations or { })
  );
  allHosts = nixosHosts ++ darwinHosts;

  # The recipient set is fleet-wide: every canonical secret is pinned to the
  # same masters, so reading it from the first host is sufficient. (Per-host
  # recipient scoping is agenix-rekey's job, in `secrets/per-host/`, not here.)
  cfg0 = (builtins.head allHosts).config.age.rekey;

  # ---- Turn a master identity into an age recipient pubkey -----------------
  # An identity may be given as a bare path, or as { identity; pubkey; }. If a
  # pubkey is supplied we trust it; otherwise we parse the referenced file:
  #   * prefer a `# Recipient: <pubkey>` comment line (age-plugin-yubikey style
  #     `.pub` files carry this), else
  #   * fall back to the first non-comment line that is itself a valid RECIPIENT
  #     (an `age1…` / `age1yubikey1…` recipient or an `ssh-ed25519`/`ssh-rsa`
  #     public key), stripping a trailing CR for CRLF safety.
  #
  # SECURITY: a bare `masterIdentities` path is `readFile`d at eval time and the
  # extracted string is written verbatim into the world-readable `/nix/store`
  # `rules.nix`. It MUST therefore be a PUBLIC recipients/`.pub` file, never a
  # plaintext age private identity. We fail closed on any private-key material
  # (`AGE-SECRET-KEY-…`, `AGE-PLUGIN-…`) rather than silently baking your fleet's
  # master decryption key into the store. If your identity file is a private
  # key, supply the `{ identity; pubkey = "age1…"; }` attrset form (honored
  # above) or point at the matching `.pub` recipients file instead.
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
          private key material (AGE-SECRET-KEY-… / AGE-PLUGIN-…). Reading it at
          eval time would leak the private key into the world-readable Nix store
          via the generated rules.nix. Supply the public recipient instead —
          either the `{ identity = <path>; pubkey = "age1…"; }` attrset form, or
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
            ${toString rec'.identity}. Expected a `# Recipient: age1…` comment
            line or a line containing an `age1…` / `ssh-ed25519` / `ssh-rsa`
            public recipient. If this is a private identity file, supply the
            `{ identity; pubkey = "age1…"; }` attrset form or a `.pub` file.'';

  fromFile = p: lib.removeSuffix "\n" (builtins.readFile p);

  masterPubkeys = (map idPubkey cfg0.masterIdentities) ++ (map fromFile cfg0.extraEncryptionPubkeys);

  # ---- Half 1 of the union: every *.age file physically on disk ------------
  fsSecrets = map (n: pathPrefix + n) (
    builtins.filter (n: lib.hasSuffix ".age" n) (builtins.attrNames (builtins.readDir secretsDir))
  );

  # ---- Half 2 of the union: every rekeyFile any host references ------------
  # A `rekeyFile` is an absolute store-ish path; normalise it back to a
  # tree-relative `<pathPrefix>....age`. This is what lets a secret appear in
  # rules.nix BEFORE its ciphertext exists: a host reference alone adds it, and
  # a later generate/encrypt step can then create the file.
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

  # ---- Render the agenix rules.nix ----------------------------------------
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
