# Prime the YubiKey PIN Cache Before Running agenix-rekey

Wrappers that let you drive [agenix-rekey](https://github.com/oddlama/agenix-rekey)
with a **YubiKey master identity** (`age-plugin-yubikey`) without the decrypt
step hanging forever.

## The problem

agenix / agenix-rekey do their crypto as an internal `decrypt | encrypt`
pipeline. When your master age identity lives on a YubiKey, `rage`/`age` has to
ask the card for its PIV **PIN** before it can decrypt. But inside that pipeline
there is no usable TTY, so instead of prompting you get:

```
A PIN is required...
```

…followed by a retry prompt that immediately hits EOF and **spins forever**.
`agenix rekey` and `agenix generate` never finish, and there is no obvious error
to grep for.

## The insight

`age-plugin-yubikey` **caches the PIN for the duration of a card session**. So
the fix is not to make the pipeline interactive — it's to satisfy the PIN prompt
*once, up front*, in a real terminal, and let the cache carry it through the
non-interactive pipeline that follows.

Each wrapper runs a tiny priming preamble before handing off to agenix:

1. Find any one committed `*.age` file to use as a throwaway "canary".
2. Only if stdin is a TTY (`[ -t 0 ]`) — so automation is never blocked —
   run a single direct `rage -d -i <identity> -o /dev/null <canary>`.
3. That interactive decrypt prompts for the PIN (and a touch, if your slot
   requires one), populating the card-session cache.
4. `exec` the real `agenix generate` / `agenix rekey -a`, which now decrypts
   straight from cache.

A failed priming is a **warning, not a hard error**: the real command still
runs and surfaces the true failure, rather than being masked by the wrapper.

## What you get

Three CLIs from one `callPackage`:

| command          | does                                                             |
|------------------|-----------------------------------------------------------------|
| `agenix-generate`| prime, then `agenix generate` (declarative generators)          |
| `agenix-rekey`   | prime, then `agenix rekey -a` (fan out to per-host keys)         |
| `agenix-encrypt` | encrypt an existing payload to the master pubkeys, no regen      |

`agenix-encrypt` is the odd one out — it does not run the agenix pipeline at
all. It scrapes the `masterPubkeys = [ ... ]` list straight out of your
generated `rules.nix` with `sed` (no flake evaluation, so it's fast and works
before any host has been evaluated) and calls `age -e -r … -o secrets/<name>.age`.
Use it when you already have a secret value and just want it encrypted to the
same recipient set, without going through a generator.

## Usage

```nix
let
  agenix-yubikey = pkgs.callPackage ./agenix-rekey-yubikey-pin-priming {
    inherit (inputs.agenix-rekey.packages.${system}) agenix-rekey;

    # REQUIRED: path (relative to your repo root) to the age-plugin-yubikey
    # identity/recipient file the priming decrypt should use.
    identityFile = "keys/age-yubikey-identity.pub";

    # Optional — these are the defaults:
    # secretsDir = "secrets";
    # rulesFile  = "secrets/rules.nix";
    # rulesHint  = "regenerate it with your agenix-rekey rules generator";
  };
in
{
  # e.g. expose them in a devShell
  devShells.default = pkgs.mkShell {
    packages = with agenix-yubikey; [ agenix-generate agenix-rekey agenix-encrypt ];
  };
}
```

`agenix-rekey`, `age`, `age-plugin-yubikey`, `rage`, and `gnused` come from the
`callPackage` scope; only `agenix-rekey` (the package that ships the rekey
`agenix` binary) usually needs to be threaded in explicitly, as above.

### Options

| argument       | default                      | meaning                                                                 |
|----------------|------------------------------|-------------------------------------------------------------------------|
| `identityFile` | *required*                   | age identity used for the priming decrypt (relative to repo root)       |
| `secretsDir`   | `"secrets"`                  | directory of flat `*.age` secrets                                       |
| `rulesFile`    | `"${secretsDir}/rules.nix"`  | rules.nix carrying `masterPubkeys = [ … ]` (used by `agenix-encrypt`)   |
| `rulesHint`    | generic message              | printed when rules.nix is missing — point it at your regen command      |

Path resolution differs by wrapper. `agenix-encrypt` resolves the repo root from
`$PRJ_ROOT`, falling back to `git rev-parse --show-toplevel`, and joins
`rulesFile`/`secretsDir` onto it — so it works from any subdirectory. The
`agenix-generate`/`agenix-rekey` priming step, by contrast, uses `secretsDir` and
`identityFile` **relative to the current working directory** (it just `find`s a
canary and runs `rage -i <identityFile>`). Run those two from your repo root.
(A failed prime is only a warning, so a wrong CWD degrades to "no priming"
rather than a hard error.)

## Caveats

- **Interactive tool.** These wrappers write into your working tree and need the
  YubiKey physically present. Run them by hand — don't call them from CI or
  unattended automation. (The TTY guard makes them safe to *invoke* there; they
  just won't prime, and the underlying command will fail loudly if it needs the
  card.)
- **Flat `secrets/*.age` layout.** The canary probe and `agenix-encrypt`'s
  output path assume secrets live directly under `secretsDir`. Nested layouts
  need the paths adjusted.
- **`agenix-encrypt` parses rules.nix textually.** It expects the conventional
  `masterPubkeys = [ "…" "…" ]` block that agenix-rekey rules generators emit,
  one quoted key per line. If your rules.nix formats that list differently,
  adjust the `sed` extraction.
- **One canary is enough.** Any decryptable secret primes the session; the
  wrapper decrypts to `/dev/null` purely for the PIN-cache side effect.
## See also

- [agenix-rekey-yubikey-pin-prime](agenix-rekey-yubikey-pin-prime.md) — a simpler single-subcommand wrapper (one binary per `callPackage` call) if you don't need the bundled `agenix-encrypt` helper.
- [agenix-yubikey-pin-prime](agenix-yubikey-pin-prime.md) — the lowest-level factory: accepts the agenix subcommand as a string or list and exposes an `agenixBin` override for non-standard binary paths.
