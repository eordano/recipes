{
  lib,
  writeShellApplication,
  agenix-rekey,
  age,
  age-plugin-yubikey,
  rage,
  gnused,

  identityFile,

  identityFilesBySerial ? { },

  secretsDir ? "secrets",

  rulesFile ? "${secretsDir}/rules.nix",

  rulesHint ? "regenerate it with your agenix-rekey rules generator",
}:

let
  serialCases = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      serial: file: "        ${serial}) primeIdentity=${lib.escapeShellArg file} ;;"
    ) identityFilesBySerial
  );

  primePreamble = ''
        canary=$(find ${lib.escapeShellArg secretsDir} -maxdepth 1 -name '*.age' -print -quit 2>/dev/null)

        # Which YubiKey is actually plugged in? Ordering by guesswork is the whole
        # problem: tools walk a fixed identity list and burn attempts on sticks that
        # are absent, failing with "device not found" -- and for FIDO ssh keys that
        # can exhaust the touch window before reaching the credential that works.
        # We are about to touch the card anyway to prime the PIN, so detect it here
        # and pick the identity that matches. age-plugin-yubikey is already a
        # runtime input; ykman is deliberately not used (its wrapper is broken on
        # darwin, and it would be an extra dependency for data we already have).
        primeIdentity=${lib.escapeShellArg identityFile}
        ykSerial=$(age-plugin-yubikey --list 2>/dev/null \
          | sed -n 's/^#[[:space:]]*Serial:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
          | head -n1)

        if [ -z "$ykSerial" ]; then
          echo "warning: no YubiKey detected (age-plugin-yubikey --list saw no card);" >&2
          echo "         falling back to ${identityFile}" >&2
        else
          case "$ykSerial" in
    ${serialCases}
            *)
              echo "warning: YubiKey serial $ykSerial is not in identityFilesBySerial;" >&2
              echo "         falling back to ${identityFile}" >&2
              ;;
          esac
          echo "YubiKey serial $ykSerial detected; priming with $primeIdentity" >&2
        fi

        if [ -t 0 ] && [ -n "$canary" ]; then
          echo "Priming YubiKey PIN via $canary (enter PIN / touch if prompted)..." >&2
          rage -d -i "$primeIdentity" -o /dev/null "$canary" \
            || echo "warning: PIN priming failed; the command below may not be able to decrypt" >&2
        fi
  '';

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
        echo "missing $rules -- ${rulesHint}" >&2
        exit 1
      fi

      if [ "$#" -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        cat >&2 <<'EOF'
      usage: agenix-encrypt <name> [plaintext-file]
        <name>          secret name (with or without .age suffix)
        plaintext-file  optional -- if omitted, plaintext is read from stdin

      Encrypts to the masterPubkeys from rules.nix. Use when you have an
      existing secret you don't want to (re)generate.
      EOF
        exit 2
      fi

      name=''${1%.age}
      case "$name" in
        */*|.*|"")
          echo "invalid name '$name' -- must be a flat secret name (no slashes, no leading dot)" >&2
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
        echo "note: $name is new -- refresh rules.nix to pick up the new recipient set" >&2
      fi
    '';
  };
in
{
  agenix-generate = generateBin;
  agenix-rekey = rekeyBin;
  agenix-encrypt = encryptBin;
}
