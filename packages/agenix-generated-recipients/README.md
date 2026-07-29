# agenix-generated-recipients

Treat agenix's recipient list (`secrets/rules.nix`) as a **generated,
committed, CI-guarded artifact** — not a file you hand-edit. Scan it from your
host configs, commit the result, and fail the build if the committed copy ever
drifts from a fresh regeneration.

## Problem

[agenix](https://github.com/ryantm/agenix) keeps a `secrets/rules.nix` (a.k.a.
`secrets.nix`) mapping each canonical `secrets/*.age` file to the set of
recipients allowed to decrypt and re-encrypt it. `agenix -e <file>` reads it to
know who to encrypt to when you edit a secret's plaintext.

Maintained by hand, this file rots the instant your setup has more than a
handful of secrets:

- you add `secrets/foo.age`, forget to list it, and `agenix -e foo` refuses to
  edit it;
- you reference `age.secrets.bar.rekeyFile = ./secrets/bar.age;` from a host but
  the ciphertext (and its rules entry) does not exist yet;
- you rotate a master key and have to retype it on every single line;
- worst of all, any of the above can happen **silently** — nothing tells you the
  committed `rules.nix` no longer matches reality until a decrypt mysteriously
  fails.

## Key insight

`rules.nix` is a **projection** of information you already state elsewhere.
Don't type it twice — generate it, commit the generated file, and let a diff
check enforce that the commit is current.

The recipe is a three-part loop:

1. **generator** — a derivation whose only output *is* the rendered `rules.nix`,
   computed from your flake:
   - **paths** = the union of every `*.age` on disk **and** every
     `age.secrets.<name>.rekeyFile` any host references (minus excluded
     subtrees). The `rekeyFile` half is what lets a secret appear in `rules.nix`
     *before* its ciphertext exists — a host reference alone adds it, so you can
     generate/encrypt it afterward.
   - **recipients** = derived from `age.rekey.masterIdentities` +
     `age.rekey.extraEncryptionPubkeys` (read from the first host, since the
     master set is fleet-wide). Each pubkey is parsed from a
     `# Recipient: <pubkey>` comment line (the age-plugin-yubikey `.pub` format)
     or, failing that, the first non-comment line of the identity file.

2. **scan** — a dev-shell command that installs the generator's output into the
   working tree. This is the deliberate "commit the artifact" step you run by
   hand and then `git add`.

3. **freshnessCheck** — a `nix flake check` derivation that regenerates and
   diffs against the committed file. **Drift → build failure.**

The commit + check pairing is the whole point. The generator alone still lets
the working copy rot the moment someone edits `rules.nix` by hand or forgets to
re-scan. The diff check turns "did you re-scan?" into a CI gate instead of a
code-review courtesy.

## Hard dependency

The recipient set is read from `config.age.rekey.*`, provided by the
[agenix-rekey](https://github.com/oddlama/agenix-rekey) NixOS/nix-darwin module
and overlay. Import its overlay into the `pkgs` that instantiate your host
configurations, or `age.rekey` will not exist and evaluation fails. The
generated file itself is plain upstream agenix format, so a decrypt/edit works
with either toolchain.

## Usage

```nix
# In your flake's per-system outputs, with `self` and `system` in scope and a
# `pkgs` that has the agenix-rekey overlay applied:

let
  recipients = pkgs.callPackage ./packages/agenix-generated-recipients {
    inherit self system;
    secretsDir = ./secrets;
    # rulesRelPath    = "secrets/rules.nix";           # default
    # pathPrefix      = "secrets/";                     # default
    # excludedSubtrees = [ "secrets/generated/" "secrets/per-host/" ];
  };
in
{
  # Run `agenix-scan-recipients` in the shell, then `git add secrets/rules.nix`.
  devShells.default = pkgs.mkShell {
    packages = [ recipients.scan /* agenix-edit, ... */ ];
  };

  # Gate drift. Pass the COMMITTED file as a path so its content is diffed.
  checks.rules-fresh = recipients.freshnessCheck ./secrets/rules.nix;
}
```

Then the workflow is: change a host's `age.secrets`, run
`agenix-scan-recipients`, `git add` the regenerated `rules.nix`, commit. If you
forget, `nix flake check` (locally or in CI) fails with a unified diff pointing
at exactly what changed.

## Options

| option | default | meaning |
| --- | --- | --- |
| `self` | — | the flake `self` (for `nixosConfigurations` / `darwinConfigurations`) |
| `system` | — | system double being evaluated; filters darwin hosts to matching systems |
| `secretsDir` | — | directory holding the `*.age` ciphertext files (e.g. `./secrets`) |
| `rulesRelPath` | `"secrets/rules.nix"` | repo-relative path the generated file is committed to |
| `pathPrefix` | `"secrets/"` | prefix on each emitted entry and matched against `rekeyFile` refs |
| `excludedSubtrees` | `[ "secrets/generated/" "secrets/per-host/" ]` | `rekeyFile` refs under these are dropped — they are derived, not source, secrets |

## Caveats & traps

- **Diff the file's content, not its store path.** `freshnessCheck` takes the
  committed `rules.nix` as a *path argument* (`./secrets/rules.nix`) precisely so
  the check compares byte content. A stringified store path would compare the
  wrong thing.
- **Determinism matters.** The paths list is sorted and de-duplicated so the
  generated output is stable; otherwise the freshness check would flap on
  attribute-ordering noise. Keep any customization deterministic.
- **The scan writes into your working tree** and (via agenix-rekey) may want a
  hardware token present to resolve master identities. Run it interactively —
  don't wire it into unattended automation. The `freshnessCheck`, by contrast,
  is pure and safe to run anywhere.
- **Excluded subtrees are load-bearing.** Per-host re-encrypted copies and
  generator scratch output are *not* source secrets; if they leak into the
  master recipient list you will encrypt derived files to the wrong key set.
  Match `excludedSubtrees` to your own directory layout.
- **Monorepo flake-in-a-subdir:** the scan command probes a subdirectory when
  `rules.nix` is not found at the toplevel. If your flake is always at the repo
  root you can ignore this; it collapses to a no-op by default.
- **masterIdentities must be PUBLIC recipients, never bare private identities.**
  The pubkey for each `age.rekey.masterIdentities` entry is parsed from a
  `# Recipient: <pubkey>` comment line, or (failing that) the first non-comment
  line of the file. A plain `age-keygen` identity has no `# Recipient:` line and
  its first non-comment line is the `AGE-SECRET-KEY-1...` **private** key — which
  would otherwise be baked into the world-readable `/nix/store` and the committed
  (pushed) `rules.nix`. The recipe **fails closed**: any candidate line that
  looks like private key material (`AGE-SECRET-KEY-`, `AGE-PLUGIN-`,
  `-----BEGIN `) throws instead of being emitted. Point `masterIdentities` at
  public recipient / `.pub` files, or supply an explicit
  `{ identity = <path>; pubkey = "age1..."; }` so the private key is never read
  for its pubkey.
- **First-host assumption:** master identities are read from the first host
  config, which is correct only if every canonical secret is pinned to the same
  master set (the common case). Genuinely per-host recipient scoping is
  agenix-rekey's job, not this generator's.
