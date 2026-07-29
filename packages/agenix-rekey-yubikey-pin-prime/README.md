# agenix-rekey-yubikey-pin-prime

A tiny wrapper around [`agenix-rekey`](https://github.com/oddlama/agenix-rekey)
that stops `agenix rekey` / `agenix generate` from **hanging forever** when your
age master identity lives on a YubiKey.

## The problem

agenix-rekey re-encrypts secrets by streaming each `.age` file through a
`decrypt | encrypt` pipeline. The decrypt half runs `rage` (or `age`) with the
pipe on its stdin.

When the identity is an [`age-plugin-yubikey`](https://github.com/str4d/age-plugin-yubikey)
key that requires a PIV **PIN**, rage prints:

```
A PIN is required...
```

…and then the retry prompt spins forever. rage wants to read the PIN from a
terminal, but its stdin is the pipe, so it immediately hits EOF and loops. The
whole `rekey` never completes and there is no obvious error — it just sits
there.

## The insight / trap

The YubiKey PIV PIN is cached **per card session**. Once you have entered it in
one successful operation, subsequent operations against the same inserted card
reuse the cached PIN without prompting.

So the fix is: **before** handing control to agenix, perform **one direct,
interactive decrypt** of any `.age` file (a "canary"). That decrypt runs with a
real TTY, so rage can prompt for the PIN (and touch, if your key is configured
touch-required). That primes the session cache. Every decrypt inside agenix's
pipeline then sails through silently.

That is the entire trick — one throwaway `rage -d ... -o /dev/null <canary>`
guarded on `[ -t 0 ]` (only when stdin is a terminal), then `exec agenix …`.

## Usage

`callPackage` it, pointing `identityFile` at your own age-plugin-yubikey
**identity** file (the `AGE-PLUGIN-YUBIKEY-…` stanza — safe to commit, since the
private key never leaves the card; a plain `age1…` recipient will not decrypt):

```nix
let
  agenix-yk = pkgs.callPackage ./default.nix {
    inherit (inputs.agenix-rekey.packages.${system}) agenix-rekey;
    identityFile = "keys/age-yubikey-identity.txt";
  };
in
  # add to a devshell, home.packages, environment.systemPackages, …
  [ agenix-yk ]
```

Run it from the **root of your secrets working tree**, with the YubiKey
inserted:

```console
$ agenix-yk-rekey            # enter PIN once, then agenix rekey -a runs clean
$ agenix-yk-rekey --dry-run  # any extra args are forwarded to agenix verbatim
```

### Options

| Argument       | Default                                | Purpose |
| -------------- | -------------------------------------- | ------- |
| `identityFile` | *(required)*                           | age-plugin-yubikey identity file (relative to the working tree) used for the priming decrypt. Must be an identity (`rage -d -i`), not a plain `age1…` recipient. |
| `subcommand`   | `"rekey"`                              | agenix-rekey subcommand to wrap; `"rekey"` or `"generate"`. |
| `secretsDir`   | `"secrets"`                            | Directory holding the `.age` canary files. |
| `extraArgs`    | `["-a"]` for rekey, `[]` for generate  | Args appended after the subcommand, before your own `$@`. |
| `name`         | `"agenix-yk-<subcommand>"`             | Binary name. |

Want both a rekey and a generate wrapper? `callPackage` it twice with different
`subcommand` values.

## Caveats

- **Interactive only.** Priming is guarded by `[ -t 0 ]`; with no TTY (CI,
  non-interactive shells) it is skipped and agenix runs unprimed. If agenix then
  needs the YubiKey it will fail — as it would anyway, since nobody can type the
  PIN. Do not run this from unattended automation.
- **Needs at least one canary.** If `secretsDir` contains no `*.age` file, there
  is nothing to prime from and the step is silently skipped. On a brand-new
  repo, `generate` may create the first secrets itself and prompt normally.
- **Session-scoped cache.** Pull the YubiKey (or start a new card session) and
  you will be prompted again on the next run — which is the point.
- The priming decrypt writes plaintext to `/dev/null`; the canary's contents are
  never exposed.
## See also

- [agenix-rekey-yubikey-pin-priming](agenix-rekey-yubikey-pin-priming.md) — the full-featured variant: ships three CLIs (`agenix-generate`, `agenix-rekey`, and `agenix-encrypt`) from one `callPackage` and can encrypt secrets directly from a parsed `rules.nix`.
- [agenix-yubikey-pin-prime](agenix-yubikey-pin-prime.md) — the lowest-level factory: accepts the agenix subcommand as a string or list and exposes an `agenixBin` override for non-standard binary paths.
