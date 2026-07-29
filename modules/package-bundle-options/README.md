# package-bundle-options

Turn named package bundles into per-host `enable` toggles, where each bundle's
human description *is* its `mkEnableOption` text — plus a `linuxOnly` helper that
silently drops Darwin-incompatible packages so one bundle set works across a
mixed Linux/macOS fleet.

## The problem

On a fleet of machines you want each host to opt into coherent *sets* of
packages — "the dev tools", "the sysadmin tools", "the desktop apps" — not to
maintain a hand-curated `environment.systemPackages` list per host. The naive
approach duplicates package lists across hosts, or scatters `lib.optionals`
throughout host configs.

## The pattern

Define bundles as an attrset. Each bundle has a `description` and a `packages`
list. A tiny bit of glue then:

1. Generates one `mkEnableOption` per bundle — **reusing the bundle's
   `description` as the option's help text**, so there's a single source of
   truth and no drift between what a bundle is called and what it contains.
2. Collects the `packages` of every bundle whose flag is set into
   `environment.systemPackages`.

A host config becomes just a list of booleans:

```nix
{
  programs.nix-helpers.enable = true;
  programs.develop.enable     = true;
  programs.sysadmin-tools.enable = true;
}
```

## The traps this encodes

### `linuxOnly` — share one bundle across Linux and Darwin

`linuxOnly ps` is the identity on Linux and `[]` on Darwin. Wrap the entries in
a shared bundle that don't build (or don't make sense) on macOS, and the *same*
bundle imports cleanly on every host — the incompatible packages just vanish on
Darwin instead of failing evaluation. Two representative reasons you reach for
it:

- **Archived / broken-on-Darwin tools.** e.g. `cargo-watch` is archived upstream
  and won't build on `aarch64-darwin` under recent nixpkgs (Cocoa module-cache
  issues in the sandbox). Prefer a cross-platform equivalent like `bacon` in the
  shared part, and `linuxOnly`-gate the holdout.
- **FUSE-linked tools.** `sshfs`'s Nix build links libfuse3 and can't drive
  macOS FUSE; on Darwin you install a fuse-t-based sshfs out of band, so the
  Nix package is Linux-only.

### The `null` filter — inline-gated packages

A bundle entry may need to be conditional on a host option (e.g. a GPU-only
package). Writing that inline as `if cond then pkg else null` is clean, but a
raw `null` in `systemPackages` crashes evaluation. The final flatten therefore
runs `filter (p: p != null)`, which makes the inline conditional safe. The
example bundle gates `btop-cuda` behind `programs.enableGpuTools`.

## Usage

Import the module and set the booleans. To adapt it, edit the `configurations`
attrset in `default.nix` — the bundle names and contents there are only
illustrative; the reusable part is the option-generation and platform-filtering
glue around them.

Every bundle automatically gains a `programs.<name>.enable` option. Options are
derived at eval time from the attrset, so adding a bundle is a one-line change
with a matching enable flag appearing for free.

## Caveats

- Bundle names must be valid attribute / option names (they become
  `programs.<name>`). Avoid clashing with real upstream `programs.*` options
  already defined by NixOS (e.g. `programs.git`); namespace your bundles if in
  doubt.
- The example gates `btop-cuda` on `programs.enableGpuTools`, a plain
  `mkEnableOption` declared alongside the generated set. Wire it to whatever
  host predicate you actually use (a hardware option, `config.hardware.*`, etc.).
- `description` is mandatory on every bundle — it is the only source of the
  option's help text.
