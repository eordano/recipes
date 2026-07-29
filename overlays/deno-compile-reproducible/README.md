# deno-compile-reproducible

Package a `deno compile` standalone binary in Nix — reproducibly, and building
fully offline in the sandbox.

## The problem

`deno compile` produces a single self-contained executable, which is exactly
what you want to ship. But it fights the Nix sandbox in two ways:

1. **It needs the network at compile time.** Deno resolves remote imports
   (`https://`, `jsr:`, `npm:` …) lazily. A naive `deno compile` inside a
   sandboxed derivation has no network and fails.
2. **It downloads a `denort` runtime zip on first compile.** Even with every
   import already cached, `deno compile` reaches out to `dl.deno.land` for the
   `denort` release matching your deno version. That download also fails
   offline — and it is easy to miss because it is separate from your imports.

## The pattern: two-phase build

**Phase 1 — `deps` (fixed-output derivation).** This is the *only* derivation
allowed network access. It runs `deno install` / `deno cache` to vendor every
remote import into `$DENO_DIR`, then content-hashes the whole directory
(`outputHashMode = "recursive"`). Because it is fixed-output, Nix grants it the
network. Bump your source rev → the import graph changes → recompute `depsHash`.

**Phase 2 — main derivation (offline).** Copies the vendored `$DENO_DIR` back in
and runs `deno compile --cached-only` so deno never touches the network. Three
traps live here:

- **Plant the `denort` zip yourself.** Fetch it with `fetchurl` (fixed-output)
  and `install` it into the exact path deno expects:

  ```
  $DENO_DIR/dl/release/v<deno.version>/denort-<target>.zip
  ```

  If you don't, `--cached-only` still tries to download it and the build dies.
  The zip must match both the deno version *and* the target triple.

- **Make the copied cache writable.** Store paths are read-only, but deno wants
  to write into `DENO_DIR` during compile. `chmod -R u+w "$DENO_DIR"` after the
  copy.

- **`dontStrip` + `dontPatchELF`.** A deno-compiled binary is an ELF with a
  payload appended after it (the embedded runtime + your code). Nix's default
  fixup phase would strip it or rewrite its interpreter and corrupt the payload.
  Both must be disabled.

## Usage

Import with `callPackage` and pass your project's parameters:

```nix
myTool = pkgs.callPackage ./deno-compile-reproducible {
  pname       = "my-tool";
  version     = "1.0.0";
  src         = pkgs.fetchFromGitHub {
    owner = "you";
    repo  = "my-tool";
    rev   = "<commit>";
    hash  = "sha256-...";
  };

  entrypoint  = "src/main.ts";     # module deno compile starts from
  cacheFiles  = [                  # everything `deno cache` must vendor
    "src/main.ts"
    "src/worker.ts"
  ];
  includes    = [ "src/worker.ts" ]; # extra modules embedded via --include

  depsHash    = "sha256-...";       # recompute when src changes
  denortHash  = "sha256-...";       # matches deno.version in your nixpkgs

  compileFlags = [                  # scope --allow-* as tightly as possible
    "--allow-net"
    "--allow-env"
    "--allow-read"
  ];
};
```

### Options

| Option | Default | Purpose |
| --- | --- | --- |
| `pname`, `version`, `src` | — | Standard package identity + fixed-output source. |
| `depsHash` | — | Hash of the vendored `$DENO_DIR` (phase 1). Recompute on any `src` change. |
| `denortHash` | — | Hash of the `denort` release zip for your deno version. |
| `entrypoint` | `"src/main.ts"` | The module `deno compile` starts from. |
| `cacheFiles` | `[ entrypoint ]` | All modules `deno cache` must vendor in phase 1. Include dynamically-imported files deno can't see statically. |
| `includes` | `[ ]` | Extra modules passed to `--include` so they're embedded in the binary. |
| `installBinaryName` | `pname` | Name under `$out/bin`. |
| `compiledOutputName` | `"compiled_binary"` | Temporary `--output` name inside the build directory, before it is installed as `installBinaryName`. |
| `compileFlags` | `--allow-net --allow-env --allow-read` | The `--allow-*` (and any other) flags for `deno compile`. |
| `denortTarget` | `x86_64-unknown-linux-gnu` | Target triple for the denort zip. |
| `patches`, `extraNativeBuildInputs`, `extraInstall`, `meta` | — | Optional passthroughs. |

## Finding the hashes

- `depsHash`: build once with a wrong/`lib.fakeHash` value and copy the
  `got: sha256-…` from the error. Re-derive after every `src` bump.
- `denortHash`: prefetch the URL for your deno version, e.g.

  ```
  nix store prefetch-file \
    https://dl.deno.land/release/v<deno.version>/denort-x86_64-unknown-linux-gnu.zip
  ```

## Caveats

- **Platform-specific.** The `denort` zip is per-target; the template defaults
  to `x86_64-unknown-linux-gnu`. Cross/other platforms need the right
  `denortTarget` and a matching `denortHash`, and typically a platform guard in
  `meta.platforms`.
- **`depsHash` is version-coupled to deno too.** A deno upgrade can change how
  imports are cached; if the deps build starts failing after a nixpkgs bump,
  recompute it.
- **`--frozen=false`** is used so a not-perfectly-matching `deno.lock` doesn't
  abort the vendor step. If you commit and trust a lockfile, drop it for
  stricter reproducibility.
- **Remote imports need `--allow-import` at compile time.** If your program
  imports over `https:`/`jsr:`/`npm:`, Deno 2 refuses to `deno compile` without
  an explicit host allowlist — *even though the imports are already cached*.
  Pass it in `compileFlags`, e.g.
  `"--allow-import=jsr.io:443,deno.land:443,esm.sh:443"`, listing every host
  your import graph reaches. This is separate from `--allow-net` (a runtime
  permission) and easy to conflate with it.
