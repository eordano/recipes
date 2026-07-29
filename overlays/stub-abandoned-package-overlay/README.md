# stub-abandoned-package-overlay

Replace an abandoned / no-longer-building package with an empty stub derivation
so a dangling reference in your closure resolves **without compiling anything** —
instead of hunting down every consumer that drags it in.

## The problem

Your system or user closure still references a package that no longer builds:
upstream abandoned it, or it fails to build against your current nixpkgs pin.
You never install it directly — it arrives *transitively*. A classic case is a
**terminfo aggregation** that enumerates every terminal emulator (`termite`
among them) just to collect their terminfo entries. One dead leaf makes the
whole thing refuse to build or evaluate.

Tracking down and patching every consumer is tedious and brittle. The reference
doesn't need a *working* package — it just needs *a* package. So give it an
empty one.

## The insight / trap

A package attribute is frequently used **two** ways at once:

- as a derivation itself — `pkgs.termite` (the binary), and
- via its sub-attributes — `pkgs.termite.terminfo` (its terminfo files).

A naive stub (`runCommand "…" {} "mkdir -p $out"`) only satisfies the first.
Any consumer reaching for `.terminfo` (or any other sub-attribute) then hits an
`attribute missing` error. The fix is the `//` operator: graft the extra
sub-attributes onto the stub derivation so **both** shapes of reference resolve:

```nix
final: prev: {
  termite = prev.runCommand "termite-stub" { } "mkdir -p $out" // {
    terminfo = prev.runCommand "termite-terminfo-stub" { } ''
      mkdir -p $out/share/terminfo
    '';
  };
}
```

That empty derivation "builds" in milliseconds and the dead reference is gone.

## Usage

`default.nix` exposes a small helper so you can parameterize the package name
and its sub-attributes:

```nix
let stub = import ./default.nix;
in {
  nixpkgs.overlays = [
    (stub {
      name = "termite";
      # sub-attributes consumers also touch -> relative dirs to create in $out
      subAttrs.terminfo = [ "share/terminfo" ];
    })
  ];
}
```

Options:

| arg        | meaning                                                                       |
|------------|-------------------------------------------------------------------------------|
| `name`     | attribute name of the abandoned package to replace                            |
| `subAttrs` | attrset `subAttrName -> [relativeDirs]`; each becomes an empty grafted stub    |

Pass `subAttrs = {}` (the default) if nothing reaches into the package's
sub-attributes.

Prefer no abstraction? The minimal copy-paste overlay at the bottom of
`default.nix` is the entire pattern — hardcode your package name and drop it
into `nixpkgs.overlays`.

## Caveats

- This is a **workaround**, not a fix. The stub provides no actual files beyond
  the empty directories you ask for. If something genuinely *uses* the package
  at runtime, stubbing it will break that use — this is only safe when the
  reference is vestigial (a build-time enumeration, a dangling default, etc.).
- Prefer the narrowest stub. Only create the sub-attributes and directories that
  are actually referenced, so you don't accidentally mask a real regression.
- Once upstream (or your nixpkgs pin) provides a building version again, drop the
  overlay so you get the real package back.
