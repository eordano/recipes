# fish-manpage-completions-fix

A one-line nixpkgs overlay that restores `create_manpage_completions.py` on disk
so home-manager's `programs.fish` completion generator keeps working against
fish 4.8+.

## The problem

fish 4.8 stopped shipping `share/fish/tools/` on disk. The manpage-completions
generator, `create_manpage_completions.py`, is now **embedded in the fish
binary** and extracted on demand rather than living as a file in the package.

home-manager's fish module hasn't caught up (in released channels). When
`programs.fish.generateCompletions` is enabled, home-manager still invokes:

```
${fish}/share/fish/tools/create_manpage_completions.py
```

That path no longer exists, so **every `<pkg>-fish-completions` derivation
fails to build** — e.g. the first thing that breaks is often a package like
`bat` whose completions home-manager tries to generate.

## The fix / key insight

fish exposes its embedded files through `status get-file`. home-manager's
development branch already extracts the generator this way; this overlay does
the same thing eagerly at package build time so the on-disk path exists again:

```nix
$out/bin/fish --no-config \
  -c 'status get-file tools/create_manpage_completions.py' \
  > $out/share/fish/tools/create_manpage_completions.py
```

The `if [ ! -e ... ]` guard makes it a no-op on older/newer fish versions that
already ship (or re-ship) the file — so it is safe to leave in place across
upgrades.

## Usage

Add the overlay to nixpkgs:

```nix
nixpkgs.overlays = [ (import ./fish-manpage-completions-fix) ];
```

or, with flakes:

```nix
pkgs = import nixpkgs {
  inherit system;
  overlays = [ (import ./fish-manpage-completions-fix) ];
};
```

No options — it patches `pkgs.fish` in place.

## Alternatives / caveats

- **Prefer disabling the generator if you can.** fish ships real, curated
  completions for common tools anyway, so setting
  `programs.fish.generateCompletions = false;` loses little and avoids the whole
  issue. Use this overlay when you specifically want home-manager to keep
  generating manpage-derived completions.
- **This is a stopgap.** Once your home-manager input carries the upstream fix
  (extracting the generator via `status get-file` itself), remove the overlay —
  the guard means keeping it around is harmless but unnecessary.
- Only affects `pkgs.fish`. If some other package pins its own fish, override
  that one too.
