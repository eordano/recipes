# python-packages-extensions-overlay

A nixpkgs overlay pattern for patching Python packages so the patch applies to
**every** interpreter version in the tree — plus a clean way to expose a Python
library as a top-level CLI only on machines that can build it.

## The problem

The obvious way to override a Python package looks like this:

```nix
final: prev: {
  python3Packages = prev.python3Packages.overrideScope (pyfinal: pyprev: {
    foo = pyprev.foo.overridePythonAttrs (old: { doCheck = false; });
  });
}
```

This only rewrites the scope bound to the **current default interpreter**. The
moment something in your tree pulls a *different* interpreter — a package pinned
to Python 3.11, a tool shipping its own `python3.env`, a cross build, or simply
`python312Packages.foo` when the default is 3.13 — it gets the **unpatched**
`foo` back.

The worst part is that this fails **silently**. The build succeeds; it just uses
the version you thought you had fixed. You disabled a flaky test, or added a
missing dependency, and it quietly didn't take.

## The insight

nixpkgs threads a list called `pythonPackagesExtensions` into the construction
of **all** interpreter package sets. Append your override to that list and it is
applied once, everywhere:

```nix
final: prev: {
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (pyfinal: pyprev: {
      foo = pyprev.foo.overridePythonAttrs (old: { doCheck = false; });
    })
  ];
}
```

Always `++` (append), never assign — other overlays contribute extensions too,
and replacing the list drops theirs.

## Layout

- **`default.nix`** — the aggregator overlay. It imports each override module,
  applies it to the top-level `prev`, and appends the results to
  `pythonPackagesExtensions`. It also shows the conditional
  `toPythonApplication` re-wrap (below).
- **`python-modules/*.nix`** — one small file per override. Keeping them separate
  makes each patch self-documenting and easy to remove when nixpkgs catches up.
- **`packages/*.nix`** — vendored derivations `callPackage`d by a module, for
  packages the pinned nixpkgs does not ship at all.

### Module signature

Each module file is a function of the top-level `prev`, returning an ordinary
python-package-set extension:

```nix
topPrev: pyfinal: pyprev: { <pkg> = ...; }
#  │        │        └─ previous python package set  (a.k.a. super)
#  │        └────────── final    python package set  (a.k.a. self)
#  └─────────────────── top-level `prev` pkgs set (for lib, fetchers, config, …)
```

- Patch an existing package with `pyprev.<pkg>.overridePythonAttrs`.
- Add a new package with `pyfinal.callPackage`.
- Reach for **`pyfinal`** (self) when a value you inject may itself be patched by
  a later extension in the list; use `pyprev` (super) for the thing you are
  overriding.

The included modules demonstrate the three recurring cases:

| module | case |
|---|---|
| `disable-sandbox-tests.nix` | drop tests that only fail in the Nix build sandbox |
| `add-missing-dependency.nix` | inject a dep the pinned nixpkgs omits |
| `vendored-package.nix` | build a package nixpkgs doesn't ship (yet) |

They use placeholder package names (`example-*`) — replace them with yours.
`vendored-package.nix` `callPackage`s `../packages/example-vendored.nix`, which
**does ship** with the recipe as a worked example: it is an ordinary
`buildPythonPackage` whose `src` hash is `lib.fakeHash`, so the attribute
evaluates cleanly and the first build prints the real hash to paste in. Replace
its `pname`/`version`/`src`/inputs with your package (or delete the module).

## Conditional library-to-application re-wrap

Some Python packages are only worth running as a CLI on hosts with the right
build support (GPU/accelerator, large toolchains). `default.nix` shows how to
expose the library as a top-level application **only** where it can build:

```nix
example-accel-tool =
  if prev.config.cudaSupport or false then
    final.python3Packages.toPythonApplication final.python3Packages.example-accel-tool
  else
    prev.example-accel-tool or null;
```

- `toPythonApplication` takes the (already-patched) library derivation and
  exposes it as a runnable top-level program.
- Pull it from `final.python3Packages` so it inherits your extensions.
- On hosts without the gate, pass the upstream attribute through, falling back
  to `null` with `or` so evaluation never throws where the attr is undefined.

Swap `cudaSupport` and `example-accel-tool` for your own gate and package.

## Gotchas

- **Append, don't replace** `pythonPackagesExtensions`.
- **`doCheck = false` is sometimes not enough.** Several nixpkgs Python packages
  moved their pytest run into `nativeInstallCheckInputs`, so it runs in the
  *installCheck* phase. Set `doInstallCheck = false` too when a test still runs
  after you disabled `doCheck`.
- The extension runs for *every* interpreter — make sure the package actually
  exists in each set, or guard with `pyprev ? <pkg>` if it may not.

## Usage

```nix
# NixOS
nixpkgs.overlays = [ (import ./python-packages-extensions-overlay) ];

# or standalone
import nixpkgs {
  overlays = [ (import ./python-packages-extensions-overlay) ];
}
```
