{
  lib,
  writeShellApplication,
  agenix-rekey,
  age-plugin-yubikey,
  rage,

  agenixSubcommand ? "generate",

  masterIdentity ? "keys/age-yubikey-identity.txt",

  secretsDir ? "secrets",

  name ? "agenix-${lib.head (lib.flatten [ agenixSubcommand ])}-pinprimed",

  agenixBin ? "${agenix-rekey}/bin/agenix",
}:

let
  subcmd = lib.concatStringsSep " " (lib.flatten [ agenixSubcommand ]);
in
writeShellApplication {
  inherit name;
  runtimeInputs = [
    agenix-rekey
    age-plugin-yubikey
    rage
  ];
  text = ''
    # --- YubiKey PIV PIN priming -----------------------------------------
    # Inside agenix's decrypt|encrypt pipeline, rage cannot prompt for the
    # YubiKey PIV PIN: it emits "A PIN is required..." and the retry prompt
    # then spins forever on EOF. The PIN is cached per card session, so we
    # prime it here with ONE direct interactive decrypt before handing over
    # to agenix. We only prime when stdin is a TTY (skips CI / piped runs).
    canary=$(find ${lib.escapeShellArg secretsDir} -maxdepth 1 -name '*.age' -print -quit 2>/dev/null)
    if [ -t 0 ] && [ -n "$canary" ]; then
      echo "Priming YubiKey PIN via $canary (enter PIN / touch if prompted)..." >&2
      rage -d -i ${lib.escapeShellArg masterIdentity} -o /dev/null "$canary" \
        || echo "warning: PIN priming failed; ${subcmd} may not be able to decrypt" >&2
    fi

    exec ${agenixBin} ${subcmd} "$@"
  '';
}
