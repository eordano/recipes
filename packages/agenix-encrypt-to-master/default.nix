{
  writeShellApplication,
  age,
  gnused,

  extraRuntimeInputs ? [ ],

  rulesPath ? "secrets/rules.nix",

  secretsDir ? "secrets",
}:
writeShellApplication {
  name = "agenix-encrypt-to-master";
  runtimeInputs = [
    age
    gnused
  ]
  ++ extraRuntimeInputs;
  text = ''
    set -euo pipefail

    # --- locate the rules file and the output directory -------------------
    # Repo root: honour a caller-set PRJ_ROOT (e.g. from a devshell), else ask
    # git. Both the rules file and the secrets dir can be pinned outright with
    # env vars, which also makes this usable outside a git checkout.
    root=''${PRJ_ROOT:-$(git rev-parse --show-toplevel)}
    rules=''${RULES_FILE:-$root/${rulesPath}}
    secrets_dir=''${SECRETS_DIR:-$root/${secretsDir}}

    if [ ! -f "$rules" ]; then
      echo "missing rules file: $rules" >&2
      echo "  point RULES_FILE at your agenix-rekey rules, or generate it first" >&2
      exit 1
    fi

    # --- argument handling ------------------------------------------------
    if [ "$#" -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
      cat >&2 <<'EOF'
    usage: agenix-encrypt-to-master <name> [plaintext-file]
      <name>          secret name (with or without .age suffix)
      plaintext-file  optional -- if omitted, plaintext is read from stdin

    Encrypts an existing plaintext to the masterPubkeys scraped from the rules
    file. Use when you have a secret you want to import as-is rather than
    (re)generate. Re-run your rekey step afterwards to fan it out to hosts.
    EOF
      exit 2
    fi

    name=''${1%.age}
    case "$name" in
      */* | .* | "")
        echo "invalid name '$name' -- must be a flat secret name (no slashes, no leading dot)" >&2
        exit 2
        ;;
    esac
    out=$secrets_dir/$name.age

    # --- scrape master recipients WITHOUT evaluating the flake ------------
    # Grab the lines between `masterPubkeys = [` and the closing `]`, then pull
    # the quoted string out of each. This is deliberately a text scrape: it is
    # fast and works before any host config has been evaluated. The trade-off
    # is that it assumes the block is laid out one quoted recipient per line:
    #
    #   masterPubkeys = [
    #     "age1..."
    #     "age1yubikey1..."
    #   ];
    mapfile -t pubkeys < <(
      sed -n '/masterPubkeys *= *\[/,/^[[:space:]]*\]/p' "$rules" \
        | sed -n 's/^[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p'
    )

    if [ "''${#pubkeys[@]}" -eq 0 ]; then
      echo "no masterPubkeys found in $rules" >&2
      echo "  expected a 'masterPubkeys = [ \"age1...\" ... ];' block, one recipient per line" >&2
      exit 1
    fi

    recip=()
    for k in "''${pubkeys[@]}"; do recip+=(-r "$k"); done

    mkdir -p "$(dirname "$out")"

    if [ -n "''${2-}" ]; then
      age -e "''${recip[@]}" -o "$out" "$2"
    else
      age -e "''${recip[@]}" -o "$out"
    fi

    echo "wrote $out (''${#pubkeys[@]} recipients)" >&2

    # A name the rules file doesn't yet list won't be rekeyed onto hosts until
    # the rules are regenerated -- warn so it isn't silently dropped.
    if ! grep -qF "$name.age" "$rules"; then
      echo "note: $name is not yet in $rules -- regenerate the rules to pick it up" >&2
    fi
  '';
}
