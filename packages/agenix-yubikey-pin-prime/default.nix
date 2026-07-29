# agenix-yubikey-pin-prime
#
# A generic factory that wraps an `agenix` subcommand (typically `generate` or
# `rekey`) with a one-shot interactive YubiKey PIV PIN "priming" step.
#
# Why: rage cannot prompt for the YubiKey PIV PIN from *inside* agenix's
# non-interactive decrypt|encrypt pipeline — it prints "A PIN is required..."
# and then spins forever on EOF. The PIN is cached per card session, so we
# perform ONE direct interactive decrypt of any existing `.age` file first
# (which is allowed to prompt), and the cached PIN then carries the whole
# unattended pipeline through.
#
# This file is a `callPackage`-able function. Call it once per agenix
# subcommand you want to wrap, e.g.:
#
#   agenix-generate = pkgs.callPackage ./agenix-yubikey-pin-prime {
#     agenixSubcommand = "generate";
#     masterIdentity   = "keys/age-yubikey-identity.txt";
#   };
#   agenix-rekey = pkgs.callPackage ./agenix-yubikey-pin-prime {
#     agenixSubcommand = [ "rekey" "-a" ];
#     masterIdentity   = "keys/age-yubikey-identity.txt";
#   };
#
# It has no NixOS-module dependencies — it produces a plain package you can
# drop into a devshell, a flake `packages` output, or `environment.systemPackages`.

{
  lib,
  writeShellApplication,
  agenix-rekey,
  age-plugin-yubikey,
  rage,

  # ---- options (all have sensible generic defaults) ----------------------

  # The agenix subcommand (plus flags) this wrapper execs after priming.
  # Accepts a string ("generate") or a list ([ "rekey" "-a" ]).
  agenixSubcommand ? "generate",

  # Path to the age-plugin-yubikey *identity* file used for the priming
  # decrypt — the `AGE-PLUGIN-YUBIKEY-…` stanza that points at the card slot.
  # Relative paths are resolved against the working directory (usually your
  # repo/project root). It is safe to keep in the repo: the private key never
  # leaves the YubiKey. A plain `age1…` RECIPIENT file (typically named
  # `*.pub`) will NOT work — `rage -d -i` needs an identity, and passing a
  # recipient makes every priming decrypt fail. The default is only an
  # identity-shaped placeholder; point it at your own file.
  masterIdentity ? "keys/age-yubikey-identity.txt",

  # Directory (relative to the working dir) that is searched, non-recursively,
  # for a canary `.age` file to decrypt for priming. Adjust to your layout.
  secretsDir ? "secrets",

  # Package name; defaults derive from the subcommand for readability.
  name ? "agenix-${lib.head (lib.flatten [ agenixSubcommand ])}-pinprimed",

  # The agenix binary to exec. Defaults to the one shipped by agenix-rekey.
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
