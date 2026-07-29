# agenix-yubikey-pin-prime

Wrap an `agenix` subcommand (`generate`, `rekey`, ...) so it runs unattended
even when your master identity lives on a **YubiKey** and requires a PIV PIN.

## The problem

When your agenix master identity is a YubiKey (via `age-plugin-yubikey`),
decrypting a secret requires the card's PIV PIN. Agenix runs its work inside a
non-interactive `decrypt | encrypt` pipeline. Inside that pipeline `rage`
**cannot prompt** for the PIN: it prints

```
A PIN is required...
```

and the retry prompt then **spins forever on EOF** — the pipeline never had a
usable TTY to type the PIN into. So `agenix rekey`/`agenix generate` hangs the
moment it needs to touch the card.

## The insight / trap

The YubiKey caches an entered PIN **per card session**. So you don't need the
PIN available inside the pipeline — you only need it entered *once* on the card
beforehand. The fix is a one-shot preamble:

> Before handing control to agenix, do a single **direct, interactive** decrypt
> of any existing `.age` file using the same YubiKey identity. That decrypt
> *is* allowed to prompt (it has a real TTY), you type the PIN (and touch if
> your slot needs it), the card caches it, and the whole agenix pipeline then
> runs through unattended.

The decrypt output is thrown away (`-o /dev/null`) — we only want the side
effect of caching the PIN on the card.

## How it works

This is a `callPackage`-able factory that produces a small
`writeShellApplication`. It:

1. Finds a canary `.age` file (non-recursive `find` in your secrets dir).
2. If stdin is a TTY and a canary exists, does one interactive
   `rage -d -i <master-identity> -o /dev/null <canary>` to prime the PIN.
   Failure here is a warning, not fatal — the subsequent agenix run will
   surface the real error.
3. `exec`s the requested `agenix` subcommand with all passthrough args.

The TTY guard (`[ -t 0 ]`) means the priming step is skipped automatically in
CI or piped invocations, where there is no PIN to enter anyway.

## Usage

Call it once per subcommand you want wrapped:

```nix
{
  agenix-generate = pkgs.callPackage ./agenix-yubikey-pin-prime {
    agenixSubcommand = "generate";
    masterIdentity   = "keys/age-yubikey-identity.txt";
  };

  agenix-rekey = pkgs.callPackage ./agenix-yubikey-pin-prime {
    agenixSubcommand = [ "rekey" "-a" ];
    masterIdentity   = "keys/age-yubikey-identity.txt";
  };
}
```

`masterIdentity` must be an **identity**, not a recipient. For
`age-plugin-yubikey` that is the file holding the `AGE-PLUGIN-YUBIKEY-…`
stanza which names the card slot (what `age-plugin-yubikey --identity` writes).
It is safe to commit — the private key never leaves the card. A plain `age1…`
recipient file (conventionally `*.pub`) will **not** work: the priming step is
`rage -d -i <file>`, and `-i` needs an identity, so a recipient makes every
prime fail with a decrypt error and leaves agenix hanging exactly as before.

Note the *binary* name is not the attribute name: it defaults to
`agenix-<subcommand>-pinprimed`, so those two calls install
`agenix-generate-pinprimed` and `agenix-rekey-pinprimed`. Pass `name` if you
want something else. Run it interactively — it primes the PIN, then behaves
exactly like the wrapped `agenix` command.

### Options

| option | default | meaning |
| --- | --- | --- |
| `agenixSubcommand` | `"generate"` | Subcommand (+ flags) to exec after priming. String or list, e.g. `[ "rekey" "-a" ]`. |
| `masterIdentity` | `"keys/age-yubikey-identity.txt"` | YubiKey **identity** file passed to `rage -d -i` (not a recipient). Relative to the working dir. Placeholder — **set this to your own path.** |
| `secretsDir` | `"secrets"` | Directory searched (depth 1) for a canary `.age` file. |
| `name` | `agenix-<first word of subcommand>-pinprimed` | Package/binary name. |
| `agenixBin` | `agenix-rekey`'s `agenix` | The agenix binary to exec. |

## Caveats

- **`masterIdentity` must be an identity file, not a recipient.** Pointing it
  at an `age1…` recipient (e.g. a `*.pub` export) makes the priming decrypt
  fail every time, which is only a warning here — so the symptom you see is
  the original hang, not an obvious error.
- The canary is *any* `.age` file that your master identity can decrypt. If
  your first-found `.age` file is **not** encrypted to the master identity,
  priming will fail (harmlessly) and the real agenix run will still hang —
  point `secretsDir` at a directory whose files the YubiKey can actually read.
- PIN caching is a property of the card/session; if your card is configured to
  require a **touch** or **PIN-per-operation**, one prime may not cover the
  whole run. Adjust your YubiKey PIV touch/PIN policy accordingly.
- Run it **interactively** — the whole point is the one TTY prompt. Under a
  non-TTY invocation it silently skips priming (by design).

## Dependencies

`agenix-rekey`, `age-plugin-yubikey`, `rage` (and `lib` from nixpkgs). All are
standard inputs; wire them via `callPackage`.
## See also

- [agenix-rekey-yubikey-pin-priming](agenix-rekey-yubikey-pin-priming.md) — the full-featured variant: ships three CLIs (`agenix-generate`, `agenix-rekey`, and `agenix-encrypt`) from one `callPackage` and can encrypt secrets directly from a parsed `rules.nix`.
- [agenix-rekey-yubikey-pin-prime](agenix-rekey-yubikey-pin-prime.md) — a mid-level wrapper with a fixed `rekey`/`generate` binary model and `subcommand`/`extraArgs` options, if the low-level factory feels like overkill.
