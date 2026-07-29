# agenix-rekey + YubiKey (age-plugin-yubikey): PIN-priming wrappers
#
# The trap this solves:
#   agenix / agenix-rekey run their crypto as an internal `decrypt | encrypt`
#   pipeline. When your master identity lives on a YubiKey (age-plugin-yubikey),
#   `rage`/`age` needs the PIV PIN to decrypt — but inside that pipeline it has
#   no usable TTY, so it prints "A PIN is required..." and then spins forever on
#   EOF instead of prompting. The PIN is cached *per card session*, so the fix
#   is to prime that cache with ONE direct, interactive `rage -d` decrypt in a
#   real terminal BEFORE handing off to `agenix generate` / `agenix rekey`.
#
# This file is a function you `callPackage` (or apply as an overlay) to get
# three drop-in CLIs:
#   * agenix-generate  — prime, then `agenix generate` (declarative generators)
#   * agenix-rekey     — prime, then `agenix rekey -a` (fan out to per-host keys)
#   * agenix-encrypt   — encrypt an existing payload to the master pubkeys
#                        without regenerating it
#
# Everything fleet-specific has been turned into an argument. The only value you
# MUST supply is `identityFile`: the path (relative to your repo root) to the
# age-plugin-yubikey identity/recipient file the priming decrypt should use.

{
  lib,
  writeShellApplication,
  # agenix-rekey's `agenix` binary (the rekey-flavoured one).
  agenix-rekey,
  # ryantm/agenix's `age` + the YubiKey plugin + rage for the priming decrypt.
  age,
  age-plugin-yubikey,
  rage,
  gnused,

  # --- configuration ------------------------------------------------------

  # Path to the age identity used to decrypt during priming, relative to the
  # repo root at runtime — e.g. "keys/age-yubikey-identity.pub". For
  # age-plugin-yubikey this is the recipient/identity stub the plugin resolves
  # to a live card session. REQUIRED.
  identityFile,

  # Directory (relative to repo root) holding your flat `*.age` secrets and the
  # generated `rules.nix`. Defaults to agenix's conventional "secrets".
  secretsDir ? "secrets",

  # Location of the agenix-rekey rules.nix (relative to repo root) that carries
  # the `masterPubkeys = [ ... ]` list agenix-encrypt encrypts to.
  rulesFile ? "${secretsDir}/rules.nix",

  # Human-readable hint printed when rules.nix is missing. Point it at whatever
  # regenerates rules.nix in your setup (e.g. your scan/refresh command).
  rulesHint ? "regenerate it with your agenix-rekey rules generator",
}:

let
  # Shared preamble: prime the YubiKey PIV PIN cache with one interactive
  # decrypt so the non-interactive agenix pipeline that follows can reuse it.
  #
  #   * Picks any one committed `*.age` file as a throwaway "canary" to decrypt.
  #   * Only runs when stdin is a TTY (`[ -t 0 ]`) — never blocks automation.
  #   * Decrypts to /dev/null; we only care about the side effect of caching
  #     the PIN in the card session.
  #   * A failed priming is a warning, not a hard error: the real command still
  #     runs (and will surface the true failure) rather than being masked here.
  primePreamble = ''
    canary=$(find ${lib.escapeShellArg secretsDir} -maxdepth 1 -name '*.age' -print -quit 2>/dev/null)
    if [ -t 0 ] && [ -n "$canary" ]; then
      echo "Priming YubiKey PIN via $canary (enter PIN / touch if prompted)..." >&2
      rage -d -i ${lib.escapeShellArg identityFile} -o /dev/null "$canary" \
        || echo "warning: PIN priming failed; the command below may not be able to decrypt" >&2
    fi
  '';

  # `agenix-rekey` (the argument) is the package providing the `agenix` binary.
  # We keep the local wrapper names distinct so they don't shadow it — `let`
  # bindings are recursive in Nix, and a local `agenix-rekey` would make
  # `${agenix-rekey}/bin/agenix` refer to itself (infinite recursion).
  generateBin = writeShellApplication {
    name = "agenix-generate";
    runtimeInputs = [
      agenix-rekey
      age-plugin-yubikey
      rage
    ];
    text = ''
      # Prime the YubiKey PIV PIN before agenix's decrypt|encrypt pipeline runs;
      # rage cannot prompt for it once inside the pipeline. See default.nix.
      ${primePreamble}
      exec ${agenix-rekey}/bin/agenix generate "$@"
    '';
  };

  rekeyBin = writeShellApplication {
    name = "agenix-rekey";
    runtimeInputs = [
      agenix-rekey
      age-plugin-yubikey
      rage
    ];
    text = ''
      # Inside agenix-rekey's decrypt|encrypt pipeline rage cannot prompt for
      # the YubiKey PIV PIN ("A PIN is required..." then a retry prompt that
      # spins forever on EOF). The PIN is cached per card session, so prime it
      # with one direct interactive decrypt first. See default.nix.
      ${primePreamble}
      exec ${agenix-rekey}/bin/agenix rekey -a "$@"
    '';
  };

  # Encrypt an existing plaintext to the master pubkeys WITHOUT regenerating it.
  # Scrapes `masterPubkeys` straight out of rules.nix with sed (no flake eval),
  # so it's fast and works before any host has been evaluated.
  encryptBin = writeShellApplication {
    name = "agenix-encrypt";
    runtimeInputs = [
      age
      age-plugin-yubikey
      gnused
    ];
    text = ''
      set -euo pipefail

      root=''${PRJ_ROOT:-$(git rev-parse --show-toplevel)}
      rules="$root/${rulesFile}"

      if [ ! -f "$rules" ]; then
        echo "missing $rules — ${rulesHint}" >&2
        exit 1
      fi

      if [ "$#" -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        cat >&2 <<'EOF'
      usage: agenix-encrypt <name> [plaintext-file]
        <name>          secret name (with or without .age suffix)
        plaintext-file  optional — if omitted, plaintext is read from stdin

      Encrypts to the masterPubkeys from rules.nix. Use when you have an
      existing secret you don't want to (re)generate.
      EOF
        exit 2
      fi

      name=''${1%.age}
      case "$name" in
        */*|.*|"")
          echo "invalid name '$name' — must be a flat secret name (no slashes, no leading dot)" >&2
          exit 2
          ;;
      esac
      out="$root/${secretsDir}/$name.age"

      # Pull every quoted string between `masterPubkeys = [` and its closing `]`.
      mapfile -t pubkeys < <(
        sed -n '/masterPubkeys *= *\[/,/^[[:space:]]*\]/p' "$rules" \
          | sed -n 's/^[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p'
      )

      if [ "''${#pubkeys[@]}" -eq 0 ]; then
        echo "no masterPubkeys found in $rules" >&2
        exit 1
      fi

      recip=()
      for k in "''${pubkeys[@]}"; do recip+=( -r "$k" ); done

      mkdir -p "$(dirname "$out")"

      if [ -n "''${2-}" ]; then
        age -e "''${recip[@]}" -o "$out" "$2"
      else
        age -e "''${recip[@]}" -o "$out"
      fi

      echo "wrote $out (''${#pubkeys[@]} recipients)" >&2
      if ! grep -qF "${secretsDir}/$name.age" "$rules"; then
        echo "note: $name is new — refresh rules.nix to pick up the new recipient set" >&2
      fi
    '';
  };
in
{
  agenix-generate = generateBin;
  agenix-rekey = rekeyBin;
  agenix-encrypt = encryptBin;
}
