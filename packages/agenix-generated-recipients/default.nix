# agenix-generated-recipients
#
# Treat agenix's recipient list (`secrets/rules.nix`, a.k.a. `secrets.nix`) as a
# GENERATED artifact: scanned from your host configs, committed to the repo, and
# guarded by a flake check that diffs a fresh regeneration against the committed
# copy — so a stale hand-edit fails CI instead of silently drifting.
#
# This bundles the three moving parts of that loop:
#
#   generator       — a derivation whose only output IS the rendered rules.nix,
#                     computed from your flake (the "source of truth").
#   scan            — a dev-shell command that installs the generator's output
#                     into the working tree (the commit step you run by hand).
#   freshnessCheck  — a `nix flake check` derivation that regenerates and diffs
#                     against the committed file; drift => build failure.
#
# The commit + check pairing is the whole point. The generator alone still lets
# the working copy rot the moment someone edits rules.nix by hand or forgets to
# re-scan after adding a secret. The diff check makes "did you re-scan?" a CI
# gate rather than a code-review courtesy.
#
# HARD DEPENDENCY: the recipient set is read from `config.age.rekey.*`, provided
# by the agenix-rekey NixOS/nix-darwin module + overlay
# (https://github.com/oddlama/agenix-rekey). Import its overlay into the `pkgs`
# that instantiate your host configurations, or `age.rekey` will not exist and
# evaluation fails. The generated file itself is plain upstream agenix
# (https://github.com/ryantm/agenix) format.
#
# callPackage-style. Typical wiring (see README for the full flake snippet):
#
#   recipients = pkgs.callPackage ./agenix-generated-recipients {
#     inherit self system;
#     secretsDir = ./secrets;
#   };
#   # devShells.default.packages = [ recipients.scan ... ];
#   # checks.<system>.rules-fresh = recipients.freshnessCheck ./secrets/rules.nix;

{
  lib,
  writeText,
  writeShellApplication,
  runCommand,
  diffutils,

  # The flake `self`, so we can read `self.nixosConfigurations` /
  # `self.darwinConfigurations`.
  self,

  # The system double being evaluated (e.g. "x86_64-linux"). Used to keep only
  # the darwin hosts that match, so a linux evaluation does not try to read
  # darwin-only identity files and vice versa.
  system,

  # Path to the directory holding the canonical `*.age` ciphertext files
  # (typically `./secrets`).
  secretsDir,

  # Repo-relative path the generated file is committed to. Emitted paths and the
  # scan command's install target both derive from this. Almost always
  # "secrets/rules.nix".
  rulesRelPath ? "secrets/rules.nix",

  # Path prefix each emitted entry carries, and the prefix `rekeyFile`
  # references are matched against. Should be the directory of `rulesRelPath`.
  pathPrefix ? "secrets/",

  # rekeyFile references whose path starts with any of these prefixes are
  # dropped from the union: agenix-rekey's derived per-host re-encryptions and
  # any generator scratch output. These are NOT source secrets and must not be
  # pinned in the master recipient list. Adjust to your directory conventions.
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
  # recipient scoping is agenix-rekey's job, not this file's.)
  cfg0 = (builtins.head allHosts).config.age.rekey;

  # ---- Turn a master identity into an age recipient pubkey -----------------
  # An identity may be a bare path or `{ identity; pubkey; }`. If a pubkey is
  # supplied we trust it; otherwise we parse the referenced file:
  #   * prefer a `# Recipient: <pubkey>` comment line (age-plugin-yubikey `.pub`
  #     files carry this), else
  #   * fall back to the first non-comment, non-empty line (a plain recipients
  #     file), stripping a trailing CR for CRLF safety.
  #
  # SAFETY: a plain `age-keygen` identity file has NO `# Recipient:` line — its
  # only non-comment line is the `AGE-SECRET-KEY-1...` PRIVATE key. Emitting that
  # into rules.nix would bake the master decryption key into the world-readable
  # /nix/store and into the committed (and pushed) rules.nix. So we fail closed:
  # any candidate line that looks like private key material throws instead of
  # being published. masterIdentities entries must be PUBLIC recipient/`.pub`
  # files, or supply an explicit `{ identity; pubkey; }`.
  privateKeyMarkers = [
    "AGE-SECRET-KEY-"
    "-----BEGIN "
    "AGE-PLUGIN-"
  ];
  isPrivateKeyMaterial =
    line: lib.any (m: lib.hasPrefix m line) privateKeyMarkers;
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

  # === Part 1: the generator ================================================
  # Its ONLY output is the rendered file. This is the single source of truth;
  # `scan` copies it into the tree and `freshnessCheck` diffs against it.
  generator = writeText "rules.nix" content;

  # === Part 2: the scan command =============================================
  # Run from the dev shell to (re)write the committed copy, then `git add` it.
  # `PRJ_ROOT` (set by e.g. devenv/direnv) wins; otherwise fall back to the git
  # toplevel. The `$root/<subdir>` probe accommodates a monorepo whose flake
  # lives in a subdirectory rather than at the repo root — drop the branch if
  # your flake is always at the toplevel.
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

  # Subdirectory probed when the flake is not at the repo toplevel. The default
  # matches the common "everything at the root" case (probe collapses to a
  # no-op because "$root/./rules.nix" == "$root/rules.nix").
  flakeSubdir = ".";

  # === Part 3: the freshness check ==========================================
  # `nix flake check` fails if the committed file differs from a fresh render.
  # Pass the COMMITTED file as a path so its content — not just its store path —
  # is what gets diffed. Wire as:
  #   checks.<system>.rules-fresh = recipients.freshnessCheck ./secrets/rules.nix;
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
          echo "${rulesRelPath} is stale — run 'agenix-scan-recipients' from the dev shell and commit the result."
          exit 1
        fi
        touch "$out"
      '';
in
{
  inherit generator scan freshnessCheck;
}
