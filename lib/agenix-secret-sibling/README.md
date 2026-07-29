# agenix-secret-sibling

A tiny helper that derives the path of a secret's **public half** from the
filename of its encrypted **private half**, for use inside
[agenix-rekey](https://github.com/oddlama/agenix-rekey) generators.

## The problem

agenix-rekey lets you register *generators*: a named shell recipe that runs when
a secret's `.age` file is missing. Whatever the recipe prints to stdout becomes
the plaintext that agenix encrypts into `<name>.age`.

Plenty of secrets are actually **key pairs**:

- an SSH host/auth key (`id_ed25519` + `id_ed25519.pub`)
- a GPG signing key (secret key + armoured `.asc` + `.fingerprint`)
- a binary-cache signing key (`priv.pem` + `<name>.pub`)
- an API key pair (`sk_...` secret + `pk_...` public)

The private half must be encrypted. The public half is **not** sensitive and you
almost always want it committed in the clear, so other modules can reference it
as a normal file. The awkward part is naming: the generator only knows the
absolute path of the target `.age` file. Where should the public file go?

## The insight

Put the public half **right beside** its encrypted private counterpart, and
derive its path from the `.age` filename — strip `.age`, append a new extension:

```
secrets/host-ssh.age    <- encrypted private key (agenix owns this)
secrets/host-ssh.pub    <- public key, plaintext, committed
```

That is the entire helper:

```nix
lib: file: suffix: lib.escapeShellArg (lib.removeSuffix ".age" file + suffix)
```

`file` is the generator argument holding the absolute path to the `.age` file;
`suffix` is the new extension (include the leading dot). The result is a
**shell-escaped** string ready to drop into the generator's shell script.

## Usage

```nix
{ lib, ... }:
let
  secretSibling = import ./lib/agenix-secret-sibling/default.nix lib;
in
{
  age.generators.ssh =
    { pkgs, file, ... }:
    ''
      ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f id_ed25519 -N "" -q
      # public half lands next to the .age, as <name>.pub
      mv id_ed25519.pub ${secretSibling file ".pub"}
      cat id_ed25519            # private half -> stdout -> encrypted by agenix
      rm id_ed25519
    '';
}
```

Then a secret opts in with `generator.script = "ssh";` and running
`agenix-rekey generate` produces both files. Multiple companions are fine — a
GPG generator can emit both `${secretSibling file ".asc"}` and
`${secretSibling file ".fingerprint"}`.

## Traps and caveats

- **`escapeShellArg` is not optional.** The path is interpolated straight into a
  shell command; escaping keeps paths with spaces or metacharacters from
  breaking (or subverting) the generator. Do not drop it "because my paths are
  simple".

- **Include the leading dot in the suffix** (`".pub"`, not `"pub"`). The suffix
  is plain string concatenation, which also means you *can* build non-dotted
  siblings if you ever need to.

- **Never leave the private half in the generator's working directory.** Emit it
  on **stdout** so agenix encrypts it, and clean up any temp files. A stray
  plaintext private key written to the current directory can silently get
  committed. Prefer a `mktemp -d` scratch dir with a cleanup `trap` for
  tools that insist on writing key files to disk:

  ```nix
  age.generators.cache-key =
    { pkgs, file, name, ... }:
    ''
      keydir=$(${pkgs.coreutils}/bin/mktemp -d)
      trap '${pkgs.coreutils}/bin/rm -rf "$keydir"' EXIT
      ${pkgs.nix}/bin/nix-store --generate-binary-cache-key \
        ${lib.escapeShellArg name} "$keydir/priv.pem" ${secretSibling file ".pub"}
      cat "$keydir/priv.pem"     # only the private half reaches stdout
    '';
  ```

- **Passphrase-less private keys are fine here.** Generators run
  non-interactively, so a GPG/SSH key generated with no passphrase is normal —
  confidentiality comes from the age encryption layer, not a key passphrase.

- The helper computes a **path only**; it does not create, move, or validate any
  file. The generator script is responsible for actually writing the public half
  to that path.

## Why a whole file for one line

Because the one line is easy to get subtly wrong (forgetting the escape, or the
dot, or re-deriving the name inconsistently across three generators), and
because the *pattern* — public sibling next to encrypted private — is the thing
worth naming and reusing across every generator in a repo.
