# agenix-rules-autogen

Stop hand-maintaining agenix's recipient list. **Derive** `secrets/rules.nix`
by scanning your flake, and gate drift with a CI freshness check.

## Problem

[agenix](https://github.com/ryantm/agenix) keeps a `secrets/rules.nix` (a.k.a.
`secrets.nix`) that maps each canonical `secrets/*.age` file to the set of
recipients it is encrypted to. `agenix -e <file>` reads it to know who may
decrypt and re-encrypt a secret when you edit its plaintext.

Maintained by hand, this file rots the moment your fleet has more than a handful
of secrets:

- you add a `secrets/foo.age`, forget to list it, and `agenix -e foo` refuses to
  edit it;
- you reference `age.secrets.bar.rekeyFile = ./secrets/bar.age;` from a host but
  the ciphertext (and its rules entry) does not exist yet;
- you rotate a master key and now have to retype it on every single line.

The recipient set is already stated declaratively elsewhere in your config
(`age.rekey.masterIdentities`), and the path set is discoverable from the
filesystem plus the host configs. So don't type it twice — generate it.

## Key insight

`rules.nix` is a **projection** of information you already have. This recipe
computes it from two sources and unions them:

1. **On-disk truth** — every `*.age` file physically present in your secrets
   directory (`builtins.readDir`).
2. **Config truth** — every `age.secrets.<name>.rekeyFile` referenced by **any**
   host in `self.nixosConfigurations` / `self.darwinConfigurations`.

The union is what makes the workflow ergonomic: **a host reference alone adds a
secret to the list, before its ciphertext exists.** That is deliberate — it lets
a later "generate" or "encrypt" step create the file for a secret that is already
declared and already scoped to the right recipients.

The **recipients** are derived too, not typed: the generator reads the first
host's `age.rekey.masterIdentities` (taking each key's `# Recipient:` comment
line, else the first non-comment line that is itself a valid `age1…` /
`ssh-*` **public recipient**) plus `age.rekey.extraEncryptionPubkeys`. Every
canonical secret is pinned to this same fleet-wide master set — so losing one
master key (e.g. a hardware token) costs convenience, not access: another master
decrypts and you rekey onto a replacement.

> **⚠️ Never point `masterIdentities` at a plaintext private key.** Each entry
> is `readFile`d **at eval time** and the extracted string is written verbatim
> into the world-readable `/nix/store` copy of `rules.nix` (and into any binary
> cache the closure is copied to). A bare path MUST be a **public**
> recipients/`.pub` file. If your master is a software age identity (a file that
> contains `AGE-SECRET-KEY-…`), do **not** pass its path — pass the
> `{ identity = <path>; pubkey = "age1…"; }` attrset form (the `pubkey` is
> trusted as-is and the private file is never read), or point at the matching
> `.pub` recipients file. The generator **fails closed**: if an identity file
> contains `AGE-SECRET-KEY-…` or `AGE-PLUGIN-…` it throws instead of leaking the
> key. YubiKey `.pub` files (with a `# Recipient:` line) are fine.

## The trap it closes

Even a generator is worthless if people keep editing the output by hand and it
silently diverges from reality. So **don't just generate — enforce.** Add a CI
check that regenerates the file and diffs it against the committed copy, failing
the build on any difference with a message telling the contributor which command
to run. Hand edits then survive only until the next check.

## Hard dependency

This reads `config.age.rekey.*`, an option tree provided by
[agenix-rekey](https://github.com/oddlama/agenix-rekey), **not** stock agenix.
You must import its overlay into the `pkgs` that build your host configurations
so that `age.rekey.masterIdentities` and `age.rekey.extraEncryptionPubkeys`
exist. This is a dependency, not a coupling you can strip — the whole "derive the
recipients" idea comes from agenix-rekey's model.

## Usage

`default.nix` is a `callPackage`-style function returning a `writeText`
derivation whose content is your `rules.nix`.

```nix
# in flake.nix, in your per-system outputs
let
  agenix-rules-nix = pkgs.callPackage ./packages/agenix-rules-autogen {
    inherit self system;
    secretsDir = ./secrets;
    # optional overrides shown with their defaults:
    # pathPrefix       = "secrets/";
    # excludedSubtrees = [ "secrets/generated/" "secrets/per-host/" ];
  };
in { ... }
```

A one-command refresher for your devShell:

```nix
agenix-auto-scan = pkgs.writeShellApplication {
  name = "agenix-auto-scan";
  text = ''
    set -euo pipefail
    root=''${PRJ_ROOT:-$(git rev-parse --show-toplevel)}
    install -m 644 ${agenix-rules-nix} "$root/secrets/rules.nix"
    echo "wrote $root/secrets/rules.nix"
  '';
};
```

And the drift-gating check (a flake `checks.<system>` entry):

```nix
checks.${system}.agenix-rules-fresh =
  pkgs.runCommand "agenix-rules-fresh"
    { expected = agenix-rules-nix; cached = ./secrets/rules.nix; }
    ''
      if ! ${pkgs.diffutils}/bin/diff -u "$cached" "$expected"; then
        echo ""
        echo "secrets/rules.nix is stale — run 'agenix-auto-scan'."
        exit 1
      fi
      touch $out
    '';
```

## Options

| Argument           | Default                                               | Meaning |
|--------------------|-------------------------------------------------------|---------|
| `self`             | —                                                     | The flake `self`; source of `nixosConfigurations` / `darwinConfigurations`. |
| `system`           | —                                                     | System double being evaluated; darwin hosts not matching it are skipped so identity files aren't cross-read. |
| `secretsDir`       | —                                                     | Path to the directory holding the canonical `*.age` files. |
| `pathPrefix`       | `"secrets/"`                                          | Prefix each emitted entry carries and that `rekeyFile` paths are matched against. |
| `excludedSubtrees` | `[ "secrets/generated/" "secrets/per-host/" ]`        | `rekeyFile` references under these prefixes are dropped — they are agenix-rekey-managed derived trees (per-host re-encrypted copies, generator scratch), **not** source secrets. Set to match your own layout. |

## Caveats

- **The excluded subtrees are your convention, not a universal one.** The
  defaults reflect a common agenix-rekey layout where per-host re-encrypted
  copies live under `secrets/per-host/` and generated material under
  `secrets/generated/`. If a `rekeyFile` in one of those trees leaks into the
  master rules list you will pin derived ciphertext to master keys — override
  `excludedSubtrees` to whatever your tree uses.
- **All secrets get the same recipient set** by design. This recipe is for the
  *source* side (the masters that open canonical secrets). Per-host recipient
  scoping is a separate concern handled by agenix-rekey.
- **`rekeyFile` paths are normalised by regex** back to `<pathPrefix>….age`.
  Keep your secrets under a single, consistently-named directory or the match
  will drop references it cannot normalise.
- Reading `masterIdentities` from the *first* host assumes the master set is
  uniform across hosts. That is the intended model here; if your hosts genuinely
  differ, this generator is the wrong tool.
