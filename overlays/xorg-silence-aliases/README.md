# xorg-silence-aliases

A nixpkgs overlay that silences the eval-time deprecation warnings emitted for
legacy `pkgs.xorg.<name>` accesses — without changing which derivation you get.

## The problem

nixpkgs has, over many releases, been **promoting packages out of the `xorg`
scope** up to the top level: `xorg.xrandr` became `xrandr`, `xorg.setxkbmap`
became `setxkbmap`, and so on. To stay backward-compatible, nixpkgs keeps the
old `xorg.<name>` attribute alive — but wraps it in a `builtins.trace`
deprecation warning. So every time *anything* in your config still reaches for
the old spelling (your own modules, or third-party modules you import), you get
a wall of:

```
trace: warning: `xorg.xrandr` is deprecated, use `xrandr` instead.
```

printed on **every** evaluation — `nixos-rebuild`, `nix build`, `nix flake
check`, CI. It's pure noise: the two spellings already resolve to the same
package. But it drowns out warnings you actually care about.

## The insight / trap

You can't easily fix every call site (some live in packages you don't own), and
you don't want to *drop* the old attribute (that would break the call sites
outright). The fix is to **re-alias each promoted name back onto `xorg`, but
point it at the promoted top-level derivation** — so the old spelling stops
being the deprecated wrapper and becomes a plain reference to the same package.
Both `xorg.xrandr` and `xrandr` then resolve to one identical derivation, and
the warning is gone.

Two subtleties this recipe bakes in:

1. **Use `final` (self), not `prev`, on the right-hand side.** `final.xrandr`
   is the fully-overlaid value, so the alias tracks any *later* overlay that
   replaces the top-level package. Aliasing to `prev.xrandr` would pin the old
   spelling to the pre-overlay derivation and silently desync the two names.

2. **Only alias names that actually exist at the top level.** Which names have
   been promoted varies by nixpkgs version. Blindly writing
   `xorg.foo = final.foo` breaks the day `foo` isn't a top-level attribute on
   your channel. This overlay filters the candidate list through
   `lib.hasAttr name final`, so unpromoted names are left untouched and the
   overlay stays a safe drop-in across channels.

## Usage

Plain overlay list:

```nix
nixpkgs.overlays = [ (import ./overlays/xorg-silence-aliases) ];
```

As a flake output:

```nix
overlays.default = import ./overlays/xorg-silence-aliases;
```

There are no options to configure — import it and the noise is gone.

## Caveats

- This only silences the *`xorg`-scope* promotions. Other unrelated nixpkgs
  deprecation warnings are untouched (by design).
- If a future nixpkgs warns about a name not in `promotedNames`, add it to the
  list in `default.nix`; the `hasAttr` filter makes extra entries harmless.
- It changes nothing about what you build — the derivations are byte-identical
  before and after. It only removes the trace output.
