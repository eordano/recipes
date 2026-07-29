# electron-bin-override

Point an Electron app at nixpkgs' **prebuilt** `electron_<N>-bin` instead of the
from-source `electron_<N>`, so you skip a huge, often-uncached Electron compile.

## The problem

nixpkgs packages Electron twice for each major version:

| attribute            | what it is                                            |
| -------------------- | ---------------------------------------------------- |
| `electron_<N>`       | Electron built from source (Chromium + Node)         |
| `electron_<N>-bin`   | The upstream prebuilt Electron tarball, repackaged   |

Many Electron desktop apps default to the from-source `electron_<N>`. Building
that locally is enormous (Chromium!) and slow — and for a given point release it
is frequently **not in the binary cache**, so you eat the full compile on your
own machine. The `-bin` variant is a fixed-output download of the official
prebuilt Electron: near-instant to realise and reliably cache-friendly.

The two are drop-in compatible for the same major version. Switching to `-bin`
costs you nothing but saves the compile.

## The insight

If a package accepts its Electron as an override-able function argument, you can
swap the source build for the prebuilt one with a single overlay:

```nix
final: prev: {
  myapp = prev.myapp.override {
    electron_39 = prev.electron_39-bin;
  };
}
```

That's the whole trick. The value is the pattern, not any one app.

## Usage

Import the overlay wherever you assemble nixpkgs:

```nix
nixpkgs.overlays = [ (import ./electron-bin-override) ];
```

or in a flake:

```nix
pkgs = import nixpkgs {
  inherit system;
  overlays = [ (import ./electron-bin-override) ];
};
```

Then edit `default.nix` for your app:

- Replace `myapp` with your app's attribute name.
- Replace `electron_39` with the exact Electron input your app takes, and
  `electron_39-bin` with the matching prebuilt attribute.

Find the right input name and confirm the `-bin` variant exists:

```sh
# what Electron argument does the app accept?
nix eval --raw nixpkgs#myapp.override.__functionArgs --apply builtins.attrNames

# does the prebuilt variant exist for that major version?
nix eval nixpkgs#electron_39-bin.version
```

## Caveats / traps

- **The `-bin` attribute must exist for that exact major version.** If the app
  pins `electron_37` but only `electron_39-bin` is packaged, this won't help
  unless you also bump the app's Electron major — which may break it.
- **`.override` only works on named arguments.** It fails silently-ish if the
  package hardcodes `electron` or wraps it differently. Check `__functionArgs`
  first (command above).
- **Keep the override scoped to the one app.** A blanket top-level
  `electron_39 = electron_39-bin` can ripple into other Electron consumers you
  didn't mean to switch.
- **It's still a fetched binary.** The prebuilt Electron is a fixed-output
  download; if it isn't cached, realising it needs network at fetch time (same
  as any FOD), it just doesn't *compile*.
