# lnd-recovery-tools-overlay

A tiny, self-contained Nixpkgs overlay that packages two Lightning/Bitcoin
operator CLIs that are **not in nixpkgs**, so you have them ready *before* the
day you need them — which, for channel recovery, is always a bad day.

- **`chantools`** — [Lightning Labs' channel rescue toolkit][chantools]. The
  last-resort kit for getting funds out of LND channels when the node itself
  won't cooperate: Static Channel Backup (SCB) recovery, force-close sweeps,
  key derivation, on-chain address sweeping, `channel.db` surgery.
- **`bbolt-cli`** — the [`bbolt`][bbolt] CLI from etcd-io. LND stores its channel
  state in `channel.db`, a BoltDB / bbolt file. When that database is what's
  wedged, you need to *look inside it* — dump buckets, check pages, inspect
  keys. This is that tool.

## The problem it solves

Both of these are the kind of thing you reach for exactly once, in an
emergency, and discover they aren't packaged. Building a Go CLI by hand under
stress — chasing the right `vendorHash`, guessing the sub-package path — is not
what you want to be doing while funds are stuck. This overlay makes them
first-class `pkgs.chantools` / `pkgs.bbolt-cli` derivations so they're already
in your system closure (or one `nix shell` away).

## Usage

Register the overlay:

```nix
nixpkgs.overlays = [ (import ./lnd-recovery-tools-overlay) ];
```

or against a bare nixpkgs import:

```nix
import <nixpkgs> { overlays = [ (import ./lnd-recovery-tools-overlay) ]; };
```

Then use the packages anywhere:

```nix
environment.systemPackages = [ pkgs.chantools pkgs.bbolt-cli ];
```

or ad-hoc, without installing anything:

```console
$ nix shell --impure --expr \
    'import <nixpkgs> { overlays = [ (import ./lnd-recovery-tools-overlay) ]; }' \
    -c chantools --version
```

## Packaging notes / traps

- **Two hashes per package.** Each derivation pins *both* the source `hash`
  (the fetched Git tag tarball) and the `vendorHash` (the whole vendored Go
  module tree). When you bump `version`, **both** change. A stale `vendorHash`
  does not silently reuse old deps — it fails the build with a hash mismatch.
  The reliable loop: set the new version, set both hashes to `lib.fakeHash`,
  build once, copy the two `got:` hashes the error prints.

- **`subPackages` picks the binary — and getting it wrong builds *nothing*,
  silently.** Neither repo has its `main` at the module root: `chantools` keeps
  it in `cmd/chantools`, and `bbolt`'s repo is primarily the *library* with its
  CLI in `cmd/bbolt`. Both therefore use `subPackages = [ "cmd/<name>" ]`. This
  overlay previously pointed `chantools` at `[ "." ]`; because the root
  directory contains no Go files at all, the build **succeeded** and installed
  an empty `$out` — no `bin/`, no binary, `mainProgram` dangling. Nothing warns
  you. After changing `subPackages`, check the output actually has the binary
  (`ls $(nix build --no-link --print-out-paths …)/bin`), don't just check that
  the build went green.

- **Upstream tests may not pass in a clean checkout.** `chantools` ships
  `TestCompactDBAndDumpChannels`, which compares against a golden dump that no
  longer matches; it is skipped via `checkFlags`. The rest of the
  `cmd/chantools` suite runs and passes, so the skip stays narrow and anchored
  (`-skip=^…$`) rather than turning `doCheck` off wholesale.

- **`-X` version stamping does *not* work here — verify before you add it.**
  An earlier revision of this overlay carried
  `-X github.com/lightningnetwork/chantools.Version=…` /
  `…Commit=…`. Those flags were dead weight, for two independent reasons, and
  both are worth internalising because a bad `-X` **fails silently**: the Go
  linker just drops a flag whose target it cannot find, so the build stays
  green and you only notice when `--version` prints nothing useful.

  1. **Wrong import path.** The fetched repo is `lightninglabs/chantools`, and
     `go.mod` says `module github.com/lightninglabs/chantools` — not
     `lightningnetwork`. `-X` takes `<importpath>.<symbol>`, so a typo'd org is
     a no-op. The module's `main` package is under `cmd/chantools` besides, not
     at the root.
  2. **The symbols are `const`, not `var`.** `cmd/chantools/root.go` declares
     `version` and `Commit` inside a `const (…)` block. `-X` can only patch
     string *variables*; constants are baked in at compile time and are
     untouchable. Upstream's own `Makefile` has the same dead
     `-X main.Commit=$(git describe --tags)`.

  The practical upshot: `chantools --version` already prints the correct
  `v<version>` (it comes from the constant) and an empty `commit`, with or
  without any linker flags. Check `go.mod` and whether the target is a `var`
  before reaching for `-X` in any Go package.

- **`bbolt-cli` is renamed to avoid a clash.** The package is `pname =
  "bbolt-cli"` but the installed binary is `bbolt` (`mainProgram`). The `pkgs`
  attribute is `bbolt-cli` so it doesn't collide with any future library-only
  `bbolt` attribute that might land in nixpkgs.

## Caveats

- Versions and hashes here are a point-in-time snapshot; bump them for your own
  deploy (see the two-hashes note above).
- These are **operator / rescue** tools. `chantools` in particular manipulates
  keys and can broadcast on-chain transactions — read its docs and work against
  backups. `bbolt` can *write* to a database file; inspect read-only unless you
  mean it, and always on a copy.

[chantools]: https://github.com/lightninglabs/chantools
[bbolt]: https://github.com/etcd-io/bbolt
