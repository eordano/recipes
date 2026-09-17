{
  lib,
  writeText,
  writeShellApplication,
  runCommand,
  diffutils,

  self,

  system,

  secretsDir,

  rulesRelPath ? "secrets/rules.nix",

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

  privateKeyMarkers = [
    "AGE-SECRET-KEY-"
    "-----BEGIN "
    "AGE-PLUGIN-"
  ];
  isPrivateKeyMaterial = line: lib.any (m: lib.hasPrefix m line) privateKeyMarkers;
  guardPub =
    src: pub:
    if isPrivateKeyMaterial pub then
      throw ''
        idPubkey: ${toString src} looks like a PRIVATE age identity (line starts with a secret-key marker).
        agenix-generated-recipients only emits PUBLIC recipients into rules.nix.
        Pass a public recipient / `.pub` file, or an explicit `{ identity = <path>; pubkey = "age1..."; }`.''
    else
      pub;
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
      if recipientLine != null then
        builtins.head (
          builtins.match "#[[:space:]]*[Rr]ecipient:[[:space:]]*([^[:space:]]+).*" recipientLine
        )
      else
        let
          nonComment = builtins.filter (l: l != "" && !(lib.hasPrefix "#" l)) lines;
        in
        if nonComment != [ ] then
          guardPub rec'.identity (lib.removeSuffix "\r" (builtins.head nonComment))
        else
          throw "idPubkey: cannot parse pubkey from ${toString rec'.identity}";

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

  generator = writeText "rules.nix" content;

  scan = writeShellApplication {
    name = "agenix-scan-recipients";
    text = ''
      set -euo pipefail
      root=''${PRJ_ROOT:-$(git rev-parse --show-toplevel)}
      if [ ! -f "$root/${rulesRelPath}" ] && [ -f "$root/${flakeSubdir}/${rulesRelPath}" ]; then
        root="$root/${flakeSubdir}"
      fi
      install -m 644 ${generator} "$root/${rulesRelPath}"
      echo "wrote $root/${rulesRelPath}"
      echo "commit it: git add ${rulesRelPath}"
    '';
  };

  flakeSubdir = ".";

  freshnessCheck =
    committed:
    runCommand "agenix-rules-fresh"
      {
        expected = generator;
        cached = committed;
      }
      ''
        if ! ${diffutils}/bin/diff -u "$cached" "$expected"; then
          echo ""
          echo "${rulesRelPath} is stale -- run 'agenix-scan-recipients' from the dev shell and commit the result."
          exit 1
        fi
        touch "$out"
      '';
in
{
  inherit generator scan freshnessCheck;
}
