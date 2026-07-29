# headplane-acl-preview-overlay

Carry a working local UI feature on top of a packaged web app — replacing an
upstream stub / "coming soon" placeholder component — using a Nix
`overrideAttrs` `postPatch`, **without forking upstream**.

The worked example targets [Headplane](https://github.com/tale/headplane)
(a Headscale admin UI). Its ACL "preview" tab ships an upstream
`<Construction />` placeholder; this overlay swaps in a real client-side access
matrix (Groups, Access Rules, SSH Rules) rendered from the policy JSON the page
already has in hand.

## The problem

You want a feature the upstream package doesn't provide yet (or renders as a
stub), but you don't want to maintain a fork: forks drift, need rebasing on
every release, and turn a one-line version bump into a merge chore. If the
package builds **from source inside its derivation** (bundling happens after
`postPatch`), you can graft the change in at package-build time and keep
tracking upstream normally.

## The insight

A UI stub swap is really four independent source edits, each with a matching
Nix/shell primitive:

| Step | Goal | Tool |
|------|------|------|
| 1 | get your component into the source tree | `cp ${./component.tsx} <dest>` |
| 2 | wire it into the page | `sed -i '1i import ...'` (imports must precede JSX) |
| 3 | put your JSX where the stub was | `substituteInPlace --replace-fail` |
| 4 | remove the leftover placeholder prose | `sed -i '/<p .../,/<\/p>/d'` |

The replacement component (`acl-preview-component.tsx`) is referenced by Nix
path, so it becomes a store input — edit it and the package rebuilds.

## Traps / gotchas

- **Use `--replace-fail`, not `--replace`.** If a future upstream release
  renames or removes the `<Construction />` placeholder, `--replace-fail` makes
  the build *fail loudly* instead of silently shipping the untouched stub. This
  is the single most important line: it turns "my patch stopped working" from a
  runtime mystery into a build error. Re-verify the anchor string on every
  version bump.
- **Append to `postPatch`, don't overwrite it.** `(old.postPatch or "") + ''…''`
  preserves any patching the upstream package already does.
- **Append to `nativeBuildInputs` too.** The in-place edits need `gnused`; add
  it defensively even if the builder already has it.
- **The import must go before line 1's JSX.** `sed '1i'` inserts a new first
  line, keeping imports at the top of the module.
- **Delete the placeholder prose, or it renders alongside your component.**
  Replacing the stub *element* (step 3) does not remove the "coming soon"
  paragraph next to it; the range delete (step 4) does. Keep the delete **last**
  so its anchor text isn't disturbed by an earlier edit.
- **Only works for source-built packages.** If the package installs a
  pre-bundled/minified artifact, there's no readable source to patch — grafting
  must happen upstream of the bundler.

## Usage

```nix
# flake.nix or configuration.nix
nixpkgs.overlays = [ (import ./headplane-acl-preview-overlay) ];
```

That's the whole wiring — the overlay overrides `pkgs.headplane` in place, so
anything that references it (a NixOS service module, a `pkgs.headplane` in an
env) picks up the patched build.

## Adapting it to another app

1. Point the `cp` destination at wherever your app expects the component.
2. Change the import path in step 2 to match.
3. Change the `--replace-fail` anchor to your placeholder's exact JSX.
4. Adjust (or drop) the step-4 range delete to match your placeholder markup.
5. Rewrite `acl-preview-component.tsx` to render your feature.

## Files

- `default.nix` — the overlay (the four-step `postPatch`).
- `acl-preview-component.tsx` — the replacement React component (a template).
