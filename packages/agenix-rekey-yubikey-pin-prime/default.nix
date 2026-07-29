# agenix-rekey-yubikey-pin-prime
#
# A thin wrapper around `agenix rekey` / `agenix generate` (from agenix-rekey)
# that first primes the YubiKey PIV PIN cache with ONE direct interactive
# decrypt of a canary `.age` file.
#
# Why: inside agenix-rekey's `decrypt | encrypt` pipeline, rage's stdin is the
# pipe, not your terminal. When the age-plugin-yubikey identity needs a PIN,
# rage prints "A PIN is required..." and then spins forever on EOF because it
# has no TTY to read the PIN from. The PIN is cached per YubiKey card session,
# so a single *interactive* decrypt (with a real TTY) fills that cache; every
# subsequent decrypt in the pipeline reuses it and never prompts.
#
# Usage (callPackage):
#
#   agenix-rekey-yubikey-pin-prime = pkgs.callPackage ./default.nix {
#     inherit (agenix-rekey.packages.${system}) agenix-rekey;
#     # required: the age-plugin-yubikey *identity* file used to decrypt.
#     identityFile = "keys/age-yubikey-identity.txt";
#     # optional overrides:
#     # subcommand  = "rekey";     # or "generate"
#     # secretsDir  = "secrets";   # where the canary *.age lives
#     # name        = "agenix-yk"; # binary name (default: agenix-yk-<subcommand>)
#   };
#
# Run it from the root of your secrets working tree, with the YubiKey inserted:
#
#   agenix-yk-rekey            # -> agenix rekey -a
#   agenix-yk-rekey --dry-run  # extra args are forwarded verbatim
#
{
  lib,
  writeShellApplication,
  agenix-rekey,
  age-plugin-yubikey,
  rage,
  # The age-plugin-yubikey *identity* file (relative to the working tree) used
  # for the priming decrypt — the `AGE-PLUGIN-YUBIKEY-…` stanza that points at
  # the card slot. It is safe to keep in the repo since the private key never
  # leaves the YubiKey; a plain `age1…` recipient will NOT work here (`rage -d
  # -i` needs an identity). No fleet-specific default — point it at your key.
  identityFile,
  # Which agenix-rekey subcommand to wrap. "rekey" re-encrypts every secret to
  # the current recipient set; "generate" creates missing generated secrets.
  subcommand ? "rekey",
  # Directory (relative to the working tree) holding the *.age canary files.
  secretsDir ? "secrets",
  # Extra args appended after the subcommand (before your own "$@").
  # For "rekey", `-a` rekeys all hosts.
  extraArgs ? (if subcommand == "rekey" then [ "-a" ] else [ ]),
  name ? "agenix-yk-${subcommand}",
}:
assert lib.assertOneOf "subcommand" subcommand [ "rekey" "generate" ];
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
