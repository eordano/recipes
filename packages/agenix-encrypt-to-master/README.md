# agenix-encrypt-to-master

Import an **existing** plaintext secret into an [agenix-rekey](https://github.com/oddlama/agenix-rekey)
tree by encrypting it to your fleet's master recipients — the counterpart to the
generators that synthesise a secret from scratch.

## The problem

agenix-rekey encrypts every secret to a small set of *master* identities (the
keys the operator holds), then rekeys each secret onto the per-host age keys at
build time. To add a secret you already have in plaintext (an API token, a
downloaded credential, a key you didn't generate yourself), you need to encrypt
it to exactly that master recipient set and drop the `.age` file in the tree.

The obvious way to learn the master recipients is to evaluate the flake and read
`age.rekey.masterIdentities` (or whatever your rules module derives from it).
That's slow, and — the real trap — **it can't run before any host has a usable
evaluation.** During bootstrap, or on a checkout whose configs don't yet
evaluate, that path is dead.

## The insight

Don't evaluate. **Scrape.**

agenix-rekey setups typically render a generated rules file that already
contains the resolved master recipients as plain string literals:

```nix
# secrets/rules.nix (generated)
{
  masterPubkeys = [
    "age1qqq…"
    "age1yubikey1…"
  ];
  # … per-secret rules …
}
```

Those are just quoted strings on their own lines. A two-line `sed` pulls them
out with no Nix evaluation at all:

```sh
sed -n '/masterPubkeys *= *\[/,/^[[:space:]]*\]/p' "$rules" \
  | sed -n 's/^[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p'
```

So encryption is fast and works the instant the rules file exists — before, and
independently of, any host evaluating.

## The rules-file contract

The scrape assumes the block is laid out **one quoted recipient per line**:

```nix
masterPubkeys = [
  "age1…"
  "age1yubikey1…"
];
```

If your generator emits recipients some other way (all on one line, a different
attribute name, computed at eval time), either adjust the `sed` in
`default.nix` or set the `rulesPath` option to point at a file that does match
this shape. The name `masterPubkeys` is what the scrape greps for; rename it in
both places if yours differs.

## Usage

Wire it in with `callPackage`:

```nix
agenix-encrypt-to-master = pkgs.callPackage ./agenix-encrypt-to-master { };
```

Then:

```sh
# from a file
agenix-encrypt-to-master my-secret ./plaintext.txt

# from stdin
printf %s "$TOKEN" | agenix-encrypt-to-master my-secret
```

It writes `secrets/my-secret.age`, encrypted to every master recipient. Re-run
your normal rekey step afterwards to fan the secret out onto the host keys.

### Options

| Option               | Default             | Purpose |
| -------------------- | ------------------- | ------- |
| `rulesPath`          | `"secrets/rules.nix"` | Repo-relative path to the rules file with the `masterPubkeys` block. |
| `secretsDir`         | `"secrets"`         | Repo-relative directory where `<name>.age` is written. |
| `extraRuntimeInputs` | `[ ]`               | Extra tools on `PATH`. See "YubiKey master keys" below. |

### Runtime environment overrides

- `PRJ_ROOT` — repo root; falls back to `git rev-parse --show-toplevel`.
- `RULES_FILE` — absolute path to the rules file, overriding `PRJ_ROOT/rulesPath`
  (lets you run outside a git checkout).
- `SECRETS_DIR` — absolute path to the output directory, overriding
  `PRJ_ROOT/secretsDir`.

### YubiKey (or other plugin) master keys

Encrypting *to* a plugin-format recipient such as `age1yubikey1…` needs the
matching age plugin binary on `PATH` even though no touch is required to
encrypt. If any master recipient is plugin-format, pass it in:

```nix
agenix-encrypt-to-master = pkgs.callPackage ./agenix-encrypt-to-master {
  extraRuntimeInputs = [ pkgs.age-plugin-yubikey ];
};
```

Plain `age1…` recipients need nothing extra, which is why the default is empty.

## Caveats

- **Flat names only.** The secret name must have no slashes and no leading dot;
  the tool rejects anything else so you can't accidentally escape the secrets
  directory.
- **A new name isn't wired up yet.** If the name isn't already present in the
  rules file, the tool warns: the secret exists and is encrypted correctly, but
  your rekey step won't fan it onto hosts until the rules are regenerated to
  include it.
- **The rules file must already exist.** This tool only encrypts; it doesn't
  generate the rules. Generate/refresh them first (or point `RULES_FILE` at an
  existing one).
- **`.age` files are re-encryptable, not append-only.** Running again with the
  same name overwrites the existing ciphertext.
