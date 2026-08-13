# cuda-setup-hook-nvcc-fix

An overlay that makes nixpkgs' CUDA setup hook put **`nvcc`'s own prefix into
`CUDAToolkit_ROOT`**, and adds `cuda_nvcc` to the `nativeBuildInputs` of the
CUDA-scope packages that need it but don't declare it.

Without it, CMake-based CUDA builds die at *configure* time with

```
CMake Error at .../Modules/FindCUDAToolkit.cmake (message):
  Could not find `nvcc` executable in path specified by variable
  CUDAToolkit_ROOT=/nix/store/...-cuda_cudart-...;/nix/store/...-libcublas-...;...
```

...while `nvcc` is sitting right there on `$PATH` and works fine if you run it.
That contradiction is the whole story, and it takes a while to see, because the
error blames a variable *the build system set for you*.

---

## Status: obsolete on current nixpkgs (retired for the 26.11 cycle)

**Both** upstream fixes have now landed, so on a recent nixpkgs this overlay has
nothing left to do and its defaults are `patchSetupHook = false` /
`nvccNativeBuildInputFor = [ ]` -- i.e. it is a no-op unless you point it at an
older pin.

- The **hook half** merged in nixpkgs PR #545542. On the pinned revision
  `setup-cuda-hook.sh` already reads `nvcc` back off `PATH`:
  ```bash
  local nvccExe
  if nvccExe="$(type -P nvcc)"; then
    addToSearchPathWithCustomDelimiter ";" CUDAToolkit_ROOT "${nvccExe%/bin/nvcc}"
  fi
  ```
- The **nativeBuildInputs half** merged earlier (nixpkgs issue #544701): both
  `cudnn-frontend/package.nix` and `cutlass.nix` now list `cuda_nvcc` themselves.

With both landed, flipping either default back on only *appends duplicates* --
a duplicated `nvccNativeBuildInputFor` entry changes the derivation hash, and
patching `setupCudaHook` forces a rebuild of it and of everything downstream (on
a CUDA host, most of the ML stack), all for a function that is byte-for-byte
equivalent to what upstream now ships. So it costs cache hits and buys nothing.

The recipe is kept only as a worked explanation and as a rescue for a nixpkgs
pin that predates the fixes -- point `scopes` at it and set the two switches on.
See [When to delete this recipe](#when-to-delete-this-recipe). The rest of this
document describes the failure it *used to* repair; read it as history unless
your pin is old.

---

## The trap, in one sentence

The CUDA setup hook fills `CUDAToolkit_ROOT` from the CUDA outputs it saw as
**host**-offset dependencies (`buildInputs`), never from the **native** one that
actually ships `bin/nvcc` -- and CMake treats a user-supplied `CUDAToolkit_ROOT`
that contains no `nvcc` as a *fatal error* instead of falling back to `PATH`.
So the hook's help is strictly worse than no hook at all.

---

## The mechanism, with citations

### 1. Where `CUDAToolkit_ROOT` comes from

`pkgs/development/cuda-modules/packages/setupCudaHook/setup-cuda-hook.sh:48-65`:

```bash
setupCUDAToolkit_ROOT() {
  (("${NIX_DEBUG:-0}" >= 1)) && echo "setupCUDAToolkit_ROOT: cudaHostPathsSeen=${!cudaHostPathsSeen[*]}" >&2

  for path in "${!cudaHostPathsSeen[@]}"; do
    addToSearchPathWithCustomDelimiter ";" CUDAToolkit_ROOT "$path"
    if [[ -d "$path/include" ]]; then
      addToSearchPathWithCustomDelimiter ";" CUDAToolkit_INCLUDE_DIR "$path/include"
    fi
  done

  # Use array form so semicolon-separated lists are passed safely.
  if [[ -n ${CUDAToolkit_INCLUDE_DIR-} ]]; then
    cmakeFlagsArray+=("-DCUDAToolkit_INCLUDE_DIR=${CUDAToolkit_INCLUDE_DIR}")
  fi
  if [[ -n ${CUDAToolkit_ROOT-} ]]; then
    cmakeFlagsArray+=("-DCUDAToolkit_ROOT=${CUDAToolkit_ROOT}")
  fi
}
preConfigureHooks+=(setupCUDAToolkit_ROOT)
```

The **only** source of entries is `cudaHostPathsSeen`. Note what is *not* in
that loop: any consultation of `PATH`, of `CUDACXX`, or of the compiler the
build is about to use.

### 2. Why `nvcc` is never in `cudaHostPathsSeen`

`cudaHostPathsSeen` is populated by an env hook registered at line 46 of the
same file:

```bash
addEnvHooks "$targetOffset" extendcudaHostPathsSeen
```

The hook body runs only when `hostOffset == -1 && targetOffset == 0` (line 5),
i.e. when the hook itself arrives as a *native* build input -- so `targetOffset`
is `0`. In `pkgs/stdenv/generic/setup.sh`, `addEnvHooks` (line 665) indexes
`pkgHookVarVars[$depHostOffset + 1]` (line 668), so offset `0` resolves through
`pkgHookVarVars` (line 659) to `pkgHostHookVars` (line 656) and hence to
`envHostHostHooks` / `envHostTargetHooks` (line 652). Under `strictDeps` (the default for CMake and Python
builders) those fire for `pkgsHostHost` and `pkgsHostTarget` -- i.e.
**`buildInputs`**. They never fire for `pkgsBuildHost`, i.e. `nativeBuildInputs`.

`cuda_nvcc` is, correctly, a *native* build input. Every CUDA redist output --
including `cuda_nvcc`'s -- carries the
`nix-support/include-in-cudatoolkit-root` marker written by
`pkgs/development/cuda-modules/packages/markForCudatoolkitRootHook/mark-for-cudatoolkit-root-hook.sh`,
so the marker is not the problem. The **offset** is. The runtime libraries
(`cuda_cudart`, `libcublas`, `libcurand`, ...) come in through `buildInputs` and
get seen; the one output with `bin/nvcc` in it comes in through
`nativeBuildInputs` and does not.

Result: `CUDAToolkit_ROOT` is a `;`-separated list of every CUDA *runtime*
output and nothing else. Inspect a real pair of outputs and the asymmetry is
obvious:

```
cuda_cudart-.../   -> include  lib  LICENSE  nix-support  share
cuda_nvcc-.../     -> bin  include  lib  LICENSE  nix-support  nvvm
                   ^^^  bin/nvcc lives only here
```

(Also worth knowing while you debug: under `strictDeps` the marker file is
deliberately left **empty** -- the marker hook `touch`es it and returns early --
so `cudaOutputToPath` stays empty and only `cudaHostPathsSeen` is meaningful.
An empty marker file is normal, not a symptom.)

### 3. Why CMake turns that into a hard failure -- and *which* CMake

This is where the version bound lives, and it is sharper than "CMake 4.x". The
same bad `CUDAToolkit_ROOT` is survivable on one CMake and fatal on the next,
because the **order** of the search steps changed.

**Affected -- CMake 4.3.4**, `Modules/FindCUDAToolkit.cmake:936-956`:

```cmake
936:  # Try user provided path
937:  if(NOT CUDAToolkit_ROOT_DIR AND DEFINED CUDAToolkit_ROOT)
938:    _CUDAToolkit_find_root_dir(SEARCH_PATHS "${CUDAToolkit_ROOT}" FIND_FLAGS PATH_SUFFIXES bin NO_DEFAULT_PATH)
939:    if(NOT CUDAToolkit_ROOT_DIR)
940:      # If the user specified CUDAToolkit_ROOT but the toolkit could not be found, this is an error.
941:      _CUDAToolkit_find_failure_message(VARIABLE)
942:    endif()
943:  endif()
...
953:  # Try users PATH, and CUDA_PATH env variable
954:  if(NOT CUDAToolkit_ROOT_DIR)
955:    _CUDAToolkit_find_root_dir(FIND_FLAGS PATHS ENV CUDA_PATH PATH_SUFFIXES bin)
956:  endif()
```

Three things matter:

- `NO_DEFAULT_PATH` on line 938 restricts `find_program(... NAMES nvcc ...)` to
  `CUDAToolkit_ROOT`. `PATH` is not consulted on this branch.
- `_CUDAToolkit_find_failure_message(VARIABLE)` (macro at
  `FindCUDAToolkit.cmake:900-920`) sets, at line 905,
  `"Could not find \`nvcc\` executable in path specified by variable
  CUDAToolkit_ROOT=${CUDAToolkit_ROOT}"` and raises it as `FATAL_ERROR` at
  line 911 whenever the `find_package` call was `REQUIRED` -- which it almost
  always is.
- The `PATH` fallback at 953-956 is therefore **unreachable**. Had the hook set
  nothing at all, that branch would have found `nvcc` on `PATH` and the build
  would have configured cleanly. The hook's "help" is what breaks it.

**Not affected -- CMake 4.1.2**, same file, `:813-831`:

```cmake
813:  # Try user provided path
814:  _CUDAToolkit_find_root_dir(COMPILER_PATHS)
815:  if(NOT CUDAToolkit_ROOT_DIR AND CUDAToolkit_ROOT)
816:    _CUDAToolkit_find_root_dir(SEARCH_PATHS "${CUDAToolkit_ROOT}" FIND_FLAGS PATH_SUFFIXES bin NO_DEFAULT_PATH)
817:  endif()
818:  if(NOT CUDAToolkit_ROOT_DIR)
819:    _CUDAToolkit_find_root_dir(FIND_FLAGS PATHS ENV CUDA_PATH PATH_SUFFIXES bin)
820:  endif()
821:
822:  # If the user specified CUDAToolkit_ROOT but the toolkit could not be found, this is an error.
823:  if(NOT CUDAToolkit_ROOT_DIR AND (DEFINED CUDAToolkit_ROOT OR DEFINED ENV{CUDAToolkit_ROOT}))
```

Here the `PATH`/`CUDA_PATH` fallback (818-820) runs **before** the error check
(823), and it has no `NO_DEFAULT_PATH`, so `find_program` reaches `$PATH`. On
4.1.x a `CUDAToolkit_ROOT` full of runtime-only outputs is harmless: `nvcc` is
found on `PATH`, `CUDAToolkit_ROOT_DIR` is set, and line 823 is never entered.
4.1.x also words the message without backticks --
`Could not find nvcc executable in path specified by variable CUDAToolkit_ROOT=...`
(line 825-826) -- which is why grepping build logs for the exact upstream string
can mislead you across versions.

**Decisive one-line test for your own CMake** (the refactor that introduced the
early abort also introduced the macro, so its presence is the marker):

```console
$ grep -q '_CUDAToolkit_find_failure_message' \
    "$(dirname "$(dirname "$(readlink -f "$(command -v cmake)")")")"/share/cmake-*/Modules/FindCUDAToolkit.cmake \
  && echo "affected: fatal BEFORE the PATH fallback" \
  || echo "not affected: PATH fallback runs first"
```

Verified: `cmake-4.3.4` -> affected; `cmake-4.1.2` -> not affected. The boundary
is somewhere in 4.2.x, so run the grep rather than reasoning from the version
number. The practical consequence is nasty: a nixpkgs bump that moves CMake
across that boundary turns a fleet of green CUDA builds red without any change
to the CUDA packages themselves.

There is a secondary rescue path -- `find_file(CUDAToolkit_SENTINEL_FILE NAMES
version.txt version.json ...)`, `FindCUDAToolkit.cmake:691-695` in 4.3.4 -- but it
carries `NO_DEFAULT_PATH` too and searches only the same `SEARCH_PATHS`, and
nixpkgs' split redist outputs are not a monolithic toolkit tree and ship no such
file. It does not help.

### 4. Why the fix is `type -P nvcc` and not a path literal

The appended function keeps the original loop and adds:

```bash
local nvccExe
if nvccExe="$(type -P nvcc)"; then
  addToSearchPathWithCustomDelimiter ";" CUDAToolkit_ROOT "${nvccExe%/bin/nvcc}"
fi
```

`nvcc` is on `PATH` precisely because it *is* a native build input -- the same
fact that excluded it from `cudaHostPathsSeen`. Reading it back off `PATH`
recovers the prefix without the overlay needing to know which `cudaPackages`
version, which output, or which store path is in play. If `nvcc` isn't on
`PATH` (a pure-runtime CUDA build), `type -P` fails, the `if` skips, and
behaviour is exactly as before -- no regression for consumers that never
needed `nvcc`.

**The `;` delimiter is load-bearing.** `CUDAToolkit_ROOT` is consumed by
`find_program(... PATHS ${arg_SEARCH_PATHS} ...)`, where CMake expands the
semicolon-separated string as a *list* of search roots. Appending with a
`:`-separated `addToSearchPath` would produce one nonsensical path and the
error would not change. Use `addToSearchPathWithCustomDelimiter ";"`, as the
upstream loop does.

---

## Trap: the hook fix alone is not sufficient

Fixing the hook makes `CUDAToolkit_ROOT` follow `nvcc` **on `PATH`**. If a
package never puts `nvcc` on `PATH` in the first place, nothing changes -- the
`type -P` lookup fails and you are back to the original error.

Two packages in the `cudaPackages` scope needed `nvcc` for their CMake config
but did not list `cuda_nvcc` in `nativeBuildInputs` (upstream nixpkgs issue
#544701 covers `cudnn-frontend`; `cutlass` had the identical defect):

- `cudnn-frontend`
- `cutlass`

With only the hook patched, `cutlass` still died at configure with the same
`Could not find ... nvcc ... in path specified by variable CUDAToolkit_ROOT=...`
error (exact wording per CMake version -- see §3). Both fixes were required;
**neither alone was sufficient**. That is why this recipe does two things at once, and why
`nvccNativeBuildInputFor` is an option rather than something hard-coded: your
nixpkgs revision may have more, or fewer, such packages.

**Check before you trust the default.** On a recent nixpkgs both packages now
declare `cuda_nvcc` themselves:

```console
$ grep -A4 -n 'nativeBuildInputs' \
    pkgs/development/cuda-modules/packages/cudnn-frontend/package.nix \
    pkgs/development/cuda-modules/packages/cutlass.nix
```

If `cuda_nvcc` is already there, the overlay appends a **duplicate** list entry.
That is functionally harmless -- `nativeBuildInputs` is deduplicated at build
time -- but it is *not* free: the duplicated list changes the derivation hash, so
you lose the binary-cache hit for those packages and everything downstream of
them. Set `nvccNativeBuildInputFor = [ ]` once your revision is fixed and you
will build the stock, cached derivations again -- which is why that is now the
default. (Historically the hook half, `patchSetupHook`, outlived the
`nativeBuildInputs` half; as of PR #545542 it too is upstream, so both defaults
are off.)

---

## Trap: `makeSetupHook` products have no phases

`setupCudaHook` is built with `makeSetupHook`
(`pkgs/development/cuda-modules/packages/setupCudaHook/package.nix`), which is a
`runCommand`-style derivation. It runs `buildCommand`; it has **no**
`installPhase`, no `postInstall`, no `postFixup`. An `overrideAttrs` that adds
`postInstall = "..."` is silently dropped -- the file is produced, the build
succeeds, and the hook is unchanged, which is a genuinely nasty way to spend an
afternoon.

The append therefore rides `buildCommand`:

```nix
setupCudaHook = cudaPrev.setupCudaHook.overrideAttrs (old: {
  buildCommand = (old.buildCommand or "") + ''
    cat >> "$out/nix-support/setup-hook" <<'HOOKFIX'
    ...
    HOOKFIX
  '';
});
```

Two sub-details:

- **`or ""`** -- never assume `buildCommand` exists; if the upstream expression
  ever switches to phases you get an eval error at the override site instead of
  a silently empty script.
- **Quoted heredoc delimiter** (`<<'HOOKFIX'`) and the delimiter at column 0.
  The body is full of `${...}` bash expansions that must survive into the file
  verbatim; in Nix source they are written `''${...}`.

## Trap: append, don't patch

The fix **redefines** `setupCUDAToolkit_ROOT` by appending a second definition
to the end of the hook script rather than editing the first one. In bash a
later function definition wins, and `preConfigureHooks+=(setupCUDAToolkit_ROOT)`
(line 66) resolves the name at *call* time, not at registration time -- so the
appended body is what runs.

Appending is what makes this survive nixpkgs bumps: a `substituteInPlace` or a
patch against `setup-cuda-hook.sh` breaks the moment upstream reflows a line,
and it breaks *loudly at build time on every CUDA host*. An append keeps working
until the function is renamed. Upstream has since landed its own fix (PR
#545542), so with `patchSetupHook = true` the append would become a harmless
no-op that still wins -- exactly the graceful end-of-life you want from a
temporary patch, and the reason the default is now `false` rather than a forced
duplicate rebuild.

---

## Secondary lesson: overlay the *scope*, and do it for **every alias**

This recipe is the cleanest worked example of a mistake that is easy to make and
very hard to see.

CUDA packages do not live at the top level of `pkgs`. They live inside a
`makeScope` package set, so the only way to change one is
`scope.overrideScope`:

```nix
cudaPackages = prev.cudaPackages.overrideScope (cudaFinal: cudaPrev: {
  cutlass = cudaPrev.cutlass.overrideAttrs (...);
});
```

An `overrideAttrs` on `prev.cudaPackages.cutlass` alone would produce a fixed
derivation that *nothing in the scope refers to* -- every other package in the
scope keeps calling the unfixed one through `cudaFinal`. Overriding the scope
re-runs the fixed point so intra-scope references pick the fix up.

**But `cudaPackages` is only one of several names pointing at these scopes.**
nixpkgs also exposes versioned attributes:

```
cudaPackages        # the default, an alias of one specific version
cudaPackages_12     # major-version alias
cudaPackages_12_9   # exact-version scope
```

These are **separate attributes**. Overriding `cudaPackages` does nothing to
`cudaPackages_12`. A consumer that pins a version -- and anything reproducible
eventually does, e.g. an inference-server expression that takes
`cudaPackages ? pkgs.cudaPackages_12` -- resolves the *unfixed* scope, and you
get the identical `Could not find nvcc` failure with an overlay that "obviously"
fixes it sitting right there in your `overlays` list. Diagnosing that costs real
time: the overlay is applied, the fix is in the store, and the failing build
just isn't looking at it.

This exact gap was the original production failure that motivated the recipe: a
speech-transcription stack pulled `cutlass` via `pkgs.cudaPackages_12`, so a
bare `cudaPackages` override never reached it.

The rule that falls out:

> When you override anything inside a versioned package scope, enumerate every
> alias your tree can reach and apply the identical transformation to each.

Hence `scopes` is a **list**, defaulted to the single conservative
`[ "cudaPackages" ]` and expected to be widened by the caller:

```nix
scopes = [ "cudaPackages" "cudaPackages_12" "cudaPackages_12_9" ];
```

The recipe filters the list against `prev ? <name>` so naming an alias that
doesn't exist on your nixpkgs is a no-op rather than an eval error -- which
matters because the set of `cudaPackages_*` attributes changes every few
nixpkgs releases.

The same shape applies to `pythonPackages` / `python3Packages` /
`python312Packages`, to `llvmPackages_*`, and to `linuxPackages_*`. See
[`python-packages-extensions-overlay`](python-packages-extensions-overlay.md)
for the Python-scope version of the same manoeuvre.

---

## Trap: guard on `cudaSupport` and return `{}`

```nix
if requireCudaSupport && !(prev.config.cudaSupport or false) then { } else ...
```

Without the guard, the overlay evaluates `prev.cudaPackages.overrideScope` on
**every** machine in the fleet, including the ones with no GPU. That does two
bad things: it drags the CUDA scope into evaluation where it was previously
untouched, and -- because `overrideScope` rebuilds the fixed point -- it can
change derivation hashes for CPU-only hosts that merely happen to reference
something in the scope, throwing away binary-cache hits for no benefit. Return
the empty attrset and CPU hosts are bit-identical to before the overlay existed.

`or false` matters too: `config.cudaSupport` is not guaranteed to be defined on
a bare `import <nixpkgs> {}`.

---

## Trap: overlays don't reach a nested `import nixpkgs`

If part of your tree is a vendored flake that does its own `import nixpkgs {...}`
rather than accepting a `pkgs` argument, **your overlays are not applied there**
-- the inner import starts from stock nixpkgs. The same hook fix has to be
inlined in that flake as well, and the two copies must be kept in step until
upstream lands the real fix. Grep for `import nixpkgs` under any vendored
directories before concluding the overlay "didn't work".

---

## Usage

On a current nixpkgs you do not need this overlay at all -- both fixes are
upstream. Only reach for it on a **pin that predates them**, and turn the two
switches back on explicitly:

```nix
# flake.nix -- only for a nixpkgs pin older than PR #545542 / issue #544701
{
  inputs.recipes.url = "github:.../recipes";

  outputs = { nixpkgs, recipes, ... }: {
    nixosConfigurations.gpu-box = nixpkgs.lib.nixosSystem {
      modules = [
        {
          nixpkgs.config.cudaSupport = true;
          nixpkgs.overlays = [
            (recipes.overlays.cuda-setup-hook-nvcc-fix {
              scopes = [ "cudaPackages" "cudaPackages_12" "cudaPackages_12_9" ];
              nvccNativeBuildInputFor = [ "cudnn-frontend" "cutlass" ];
              patchSetupHook = true;
              requireCudaSupport = true;
            })
          ];
        }
        ./configuration.nix
      ];
    };
  };
}
```

With the shipped defaults (`patchSetupHook = false`,
`nvccNativeBuildInputFor = [ ]`) the overlay is a no-op that leaves every
derivation hash untouched, so leaving it in a modern tree is harmless but
pointless -- prefer deleting it (see below).

Or standalone, without flakes:

```nix
import <nixpkgs> {
  config.cudaSupport = true;
  overlays = [
    (import ./overlays/cuda-setup-hook-nvcc-fix { scopes = [ "cudaPackages" "cudaPackages_12" ]; })
  ];
}
```

### Options

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `scopes` | list of attribute names | `[ "cudaPackages" ]` | Which `pkgs.<name>` CUDA scopes to fix. **Name every alias your tree resolves.** Names absent from `pkgs` are skipped. |
| `nvccNativeBuildInputFor` | list of scope-package names | `[ ]` | Packages inside each scope that get `cuda_nvcc` appended to `nativeBuildInputs`. Empty by default because upstream fixed `cudnn-frontend` and `cutlass` (issue #544701); on an older pin set e.g. `[ "cudnn-frontend" "cutlass" ]`. Names absent from the scope are skipped. |
| `extraCmakeFlagsFor` | attrset (package name -> list of flags) | `{ }` | Extra `cmakeFlags` per scope package. Any existing flag setting the same CMake variable is dropped first, so yours win regardless of what nixpkgs set. |
| `extraPostInstallFor` | attrset (package name -> shell snippet) | `{ }` | Shell appended to a package's `postInstall`. Mainly the fallout of `extraCmakeFlagsFor`: turning a cmake target off can leave a declared output empty, which Nix rejects -- populate/create it here. |
| `patchSetupHook` | bool | `false` | Append the fixed `setupCUDAToolkit_ROOT` to `setupCudaHook`. Off by default because the hook fix landed upstream (PR #545542); set `true` only on a pin that predates it. |
| `requireCudaSupport` | bool | `true` | Return `{}` unless `config.cudaSupport` is set, so non-GPU hosts are untouched. |

Every list is filtered against what actually exists, so the overlay degrades to
a partial (or empty) fix on an unexpected nixpkgs instead of failing evaluation.

---

## Verifying it worked

**Cheapest check -- the hook script itself:**

```console
$ nix build --no-link --print-out-paths \
    '.#legacyPackages.x86_64-linux.cudaPackages_12.setupCudaHook'
$ grep -c 'type -P nvcc' <that path>/nix-support/setup-hook
1
```

Zero means the overlay didn't reach that scope -- the most likely cause is the
alias trap above.

**Runtime check -- watch the hook decide:**

```console
$ NIX_DEBUG=1 nix build '.#...' 2>&1 | grep setupCUDAToolkit_ROOT
setupCUDAToolkit_ROOT: cudaHostPathsSeen=/nix/store/...-cuda_cudart-... /nix/store/...-libcublas-...
```

If `cudaHostPathsSeen` lists only `lib`-ish outputs and no `bin/nvcc`-bearing
one, you are looking at the exact condition this recipe repairs.

**Config-time check -- the flag CMake actually got:**

```console
$ grep -o '\-DCUDAToolkit_ROOT=[^ ]*' <build log>
```

After the fix, the last `;`-separated element is the `cuda_nvcc` prefix.

**Regression check when you change the overlay:** compare derivation paths, not
build success. `nix eval --raw '.#nixosConfigurations.<host>.config.system.build.toplevel.drvPath'`
before and after -- an identical `drvPath` proves the entire closure is
unchanged, which is a far stronger statement than "it still builds".

---

## What upstream nixpkgs now does (both halves landed)

On the pinned revision -- and on any recent nixpkgs -- upstream has closed **both**
halves of this problem, which is why this recipe is retired by default:

- **The hook half is fixed.** `setup-cuda-hook.sh` (around line 58-60 on the pin,
  the exact number drifts) now reads `nvcc` back off `PATH` after the
  `cudaHostPathsSeen` loop:
  ```bash
  local nvccExe
  if nvccExe="$(type -P nvcc)"; then
    addToSearchPathWithCustomDelimiter ";" CUDAToolkit_ROOT "${nvccExe%/bin/nvcc}"
  fi
  ```
  This is exactly the append this recipe used to inject, merged upstream as PR
  #545542. So `CUDAToolkit_ROOT` now includes the `cuda_nvcc` prefix out of the
  box and the CMake `FATAL_ERROR` described above no longer fires.
- **The `nativeBuildInputs` half is fixed.**
  `pkgs/development/cuda-modules/packages/cudnn-frontend/package.nix` and
  `pkgs/development/cuda-modules/packages/cutlass.nix` both list `cuda_nvcc` in
  their `nativeBuildInputs` (nixpkgs issue #544701), so `nvcc` reaches `PATH`
  without help.

The two facts that remain true and still make good background reading: there is
still no option, attribute or `config` flag to *disable* the `CUDAToolkit_ROOT`
export -- `dontSetupCUDAToolkitCompilers` turns off the *compiler* half of the
hook only -- and the CMake `find_package` behaviour that made a bad
`CUDAToolkit_ROOT` fatal (see §3) is unchanged. Upstream simply stopped exporting
a bad one.

## When to delete this recipe

Both upstream fixes are in, so on a current pin the answer is **delete it** (or
just leave the defaults off; a no-op overlay changes no derivation hash). Keep it
only if you are stuck on a nixpkgs pin that predates the fixes. Two-minute check,
run from a nixpkgs checkout:

```console
$ grep -q 'type -P nvcc' pkgs/development/cuda-modules/packages/setupCudaHook/setup-cuda-hook.sh && echo hook-fixed
$ grep -q 'cuda_nvcc' pkgs/development/cuda-modules/packages/cudnn-frontend/package.nix && echo pkg-fixed
```

- Both print (the current case, and the shipped default posture): delete the
  overlay, or leave it with `patchSetupHook = false` / `nvccNativeBuildInputFor
  = [ ]` -- either way it does nothing.
- Only `pkg-fixed` prints (older pin, hook not yet in): set `patchSetupHook =
  true`, `nvccNativeBuildInputFor = [ ]`.
- Only `hook-fixed` prints: set `patchSetupHook = false`,
  `nvccNativeBuildInputFor = [ "cudnn-frontend" "cutlass" ]`.
- Neither prints (a genuinely old pin): turn both on.

Turning either switch on against a nixpkgs that already carries the fix is
*functionally* harmless -- the appended function is equivalent to what upstream
defines, and a later bash definition wins -- but it is not free: it appends a
duplicate `nativeBuildInputs` entry and/or rebuilds `setupCudaHook`, changing
derivation hashes and throwing away the binary-cache hit for `setupCudaHook` and
everything downstream of it (on a CUDA host, most of the ML stack). That is the
whole reason the defaults are now off. Removing the overlay entirely is worth a
deploy.

---

## Related recipes

- [`python-packages-extensions-overlay`](python-packages-extensions-overlay.md)
  -- the same "override the scope, not the leaf" pattern for Python package sets.
- [`skip-flaky-tests-overlay`](skip-flaky-tests-overlay.md) -- companion for the
  *other* half of getting heavy GPU/ML builds through: check phases that fail
  for reasons unrelated to the code.
- [`unstable-cherry-pick-overlay`](unstable-cherry-pick-overlay.md) -- when the
  upstream fix exists but only on a newer channel and you'd rather pull the
  package than carry a patch.
- [`nixpkgs-fork-overlay-protoc-and-ebpf`](nixpkgs-fork-overlay-protoc-and-ebpf.md)
  -- for when the change is too large to express as an append and you need a
  whole forked package set.

## License

CC0 1.0 Universal (public domain).
