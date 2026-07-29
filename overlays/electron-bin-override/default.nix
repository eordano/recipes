# electron-bin-override
#
# A nixpkgs overlay that points an Electron app at the *prebuilt* `-bin`
# variant of Electron instead of the from-source build.
#
# WHY: nixpkgs ships Electron in two flavours per major version:
#   - `electron_<N>`      — built from source (Chromium + Node). Huge, slow,
#                           and frequently NOT in the binary cache for a given
#                           point release, so you compile it locally for hours.
#   - `electron_<N>-bin`  — the upstream prebuilt Electron tarball, downloaded
#                           and repackaged. Tiny to "build", always cache-hits.
#
# Any package that takes `electron_<N>` as an override-able input can be told to
# use the `-bin` variant instead. The two are drop-in compatible: same major
# version, same ABI, same app behaviour — you just skip the compile.
#
# USAGE — this file is a plain overlay. Wire it in wherever you assemble
# nixpkgs, e.g.:
#
#   nixpkgs.overlays = [ (import ./electron-bin-override) ];
#
# or in a flake:
#
#   pkgs = import nixpkgs {
#     inherit system;
#     overlays = [ (import ./electron-bin-override) ];
#   };
#
# Then rebuild the app package (here `myapp`) as usual.
#
# ADAPT to your app: replace `myapp` with the attribute name of your Electron
# app, and `electron_39` with the exact Electron input that package's function
# accepts. Find the right input name with:
#
#   nix eval --raw nixpkgs#myapp.override.__functionArgs --apply builtins.attrNames
#
# and confirm the `-bin` variant exists (e.g. `nixpkgs#electron_39-bin`).
#
# TRAP / GOTCHAS:
#   - The `-bin` attribute must exist for that exact major version. If your app
#     pins `electron_37` but only `electron_39-bin` is packaged, this won't help
#     without also bumping the app's Electron major (which may break it).
#   - `.override { electron_N = ...; }` only works if the package actually takes
#     `electron_N` as a named argument. Some packages hardcode `electron` or
#     wrap it differently — check `__functionArgs` first.
#   - The prebuilt Electron is an unfree-ish upstream binary blob. If you build
#     with a strict sandbox / no network and it isn't cached, the fixed-output
#     download still needs network at fetch time (same as any FOD).
#   - Keep this override scoped to the one app. A blanket `electron_39 =
#     electron_39-bin` at the top level can ripple into other consumers you did
#     not intend to switch.

final: prev: {
  myapp = prev.myapp.override {
    electron_39 = prev.electron_39-bin;
  };
}
