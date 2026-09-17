{
  lib,
  writeShellApplication,
  agenix-rekey,
  age-plugin-yubikey,
  rage,
  identityFile,
  subcommand ? "rekey",
  secretsDir ? "secrets",
  extraArgs ? (if subcommand == "rekey" then [ "-a" ] else [ ]),
  name ? "agenix-yk-${subcommand}",
}:
assert lib.assertOneOf "subcommand" subcommand [
  "rekey"
  "generate"
];
writeShellApplication {
  inherit name;
  runtimeInputs = [
    agenix-rekey
    age-plugin-yubikey
    rage
  ];
  text = ''
    # --- YubiKey PIV PIN priming ---------------------------------------------
    # Inside agenix-rekey's decrypt|encrypt pipeline rage cannot prompt for the
    # YubiKey PIV PIN: it prints "A PIN is required..." and then the retry
    # prompt spins forever on EOF (no TTY on the pipe). The PIN is cached per
    # card session, so prime it here with one direct interactive decrypt of any
    # secret before handing control to agenix.
    #
    # Guarded by `[ -t 0 ]`: only prime when stdin is a real terminal. In CI or
    # non-interactive shells there is nothing to type a PIN into anyway, so we
    # skip straight to agenix (which will fail loudly if it needs the key).
    canary=$(find ${lib.escapeShellArg secretsDir} -maxdepth 1 -name '*.age' -print -quit 2>/dev/null || true)
    if [ -t 0 ] && [ -n "$canary" ]; then
      echo "Priming YubiKey PIN via $canary (enter PIN / touch if prompted)..." >&2
      rage -d -i ${lib.escapeShellArg identityFile} -o /dev/null "$canary" \
        || echo "warning: PIN priming failed; ${subcommand} may not be able to decrypt" >&2
    fi

    exec ${agenix-rekey}/bin/agenix ${subcommand} ${lib.escapeShellArgs extraArgs} "$@"
  '';
}
