# Rebuild a Package Against a Vendored Fork (Protoc + eBPF Traps)

Rebuild an existing **nixpkgs** package against your **own fork of its source**
without repackaging it from scratch — you inherit nixpkgs' build recipe and swap
only `src`, `version`, `vendorHash`, and drop the patch set.

The worked example is a project shaped like `opensnitch`: a **Go daemon + PyQt
UI + eBPF kernel module**. The same pattern applies to any nixpkgs derivation
whose upstream you've forked.

## The problem

nixpkgs ships version *N* of a package with its own patch set. You have a fork
(a redesigned feature, a bugfix, a private branch) at version *N+1* and want
your fleet to build *your* tree while reusing nixpkgs' packaging work.

The naive `overrideAttrs { src = myFork; }` gets you 80% there and then breaks in
two non-obvious ways. This overlay encodes the fixes.

## The two traps

### 1. A git-archived source lacks gitignored codegen output dirs

A vendored fork (a flake `path:` input, a `git archive`, a `fetchFromGitHub`
tarball) contains **tracked source only**. Any directory upstream lists in
`.gitignore` — very commonly the **protoc output dirs** — is simply absent from
the checkout.

The build's codegen step (here `proto/Makefile` running `protoc`) then tries to
*write* generated stubs into those missing dirs and fails with:

```
No such file or directory
```

The fix: wrap the raw source in a `runCommand` that `mkdir -p`'s the output dirs
**before** the build runs. That `namedSrc` wrapper is the whole reason this isn't
a one-line override. Don't strip it.

```nix
namedSrc = prev.runCommand "${pname}-${version}-source" { } ''
  cp -r ${forkSrc.outPath or forkSrc} $out
  chmod -R u+w $out
  mkdir -p $out/daemon/ui/protocol $out/ui/opensnitch/proto
'';
```

### 2. `overrideAttrs` can't reach the eBPF kernel-module subpackage

The eBPF object is built **per kernel** via `linuxKernel.packagesFor`. An
`overrideAttrs` on the *top-level* derivation never touches it, so your
`patches = [ ]` doesn't propagate there — and nixpkgs' patches (written against
the older upstream tree) fail to apply to your fork.

The fix is to extend `packagesFor` so **every** kernel's build of the subpackage
also drops its patches:

```nix
linuxKernel = prev.linuxKernel // {
  packagesFor = kernel:
    (prev.linuxKernel.packagesFor kernel).extend (lpFinal: lpPrev: {
      opensnitch-ebpf = lpPrev.opensnitch-ebpf.overrideAttrs { patches = [ ]; };
    });
};
```

## Why `patches = [ ]` everywhere

nixpkgs' patches target the *upstream* tree. Once you point `src` at a fork at a
different version, those patches no longer apply and the build fails at the patch
phase. Dropping them (`patches = [ ]`) on the daemon, the UI, **and** the eBPF
subpackage is deliberate — your divergence should live in the fork's own tree,
not in overlay-side `.patch` files.

## Usage

```nix
# flake.nix
inputs.myfork.url = "github:you/your-fork";   # or path:./vendor/your-fork

# where you build nixpkgs:
overlays = [
  (import ./overlays/nixpkgs-fork-overlay-protoc-and-ebpf {
    forkSrc    = inputs.myfork;
    version    = "1.9.0";              # the FORK's own version string
    vendorHash = "sha256-AAAA...=";    # recompute when go.mod/go.sum change
  })
];
```

### Options

| option | default | purpose |
| --- | --- | --- |
| `forkSrc` | *(required)* | the vendored fork source (flake input / `path:` / fetcher result) |
| `version` | *(required)* | the fork's own version string (see caveat below) |
| `vendorHash` | *(required)* | Go module vendor hash; recompute on go.mod/go.sum changes |
| `pname` | `"opensnitch"` | nixpkgs attr name of the daemon derivation |
| `uiPname` | `"opensnitch-ui"` | nixpkgs attr name of the UI derivation |
| `ebpfPname` | `"opensnitch-ebpf"` | nixpkgs attr name of the eBPF subpackage |
| `protocOutputDirs` | `[ "daemon/ui/protocol" "ui/opensnitch/proto" ]` | gitignored codegen dirs to pre-create |
| `uiSubdir` | `"ui"` | source subdir the UI derivation builds from |
| `doCheck` | `false` | run the daemon test suite |

To recompute `vendorHash`, set it to `pkgs.lib.fakeHash` (or any wrong value),
build once, and paste the hash Nix reports back into your call.

## Caveats

- **The `version` is your fork's number, not an upstream tag.** `nix flake
  update` won't advance it — it moves only when you deliberately re-vendor and
  re-pin the fork rev. Keep `vendorHash` in sync with that rev.
- **`vendorHash` is pinned in the overlay.** Any change to the fork's
  `go.mod`/`go.sum` requires recomputing it, or the `goModules` build fails with
  a hash mismatch.
- **`doCheck` defaults to off** because the example project's upstream test
  suite has a flaky race. If your fork's tests are reliable, set `doCheck =
  true`.
- **Binary-path–sensitive consumers.** If downstream config matches the built
  binary by its `/nix/store/...-<pkg>-.../bin/...` path (e.g. a firewall
  ruleset), a rename introduced by the version bump (wrapped vs unwrapped,
  `-wrapped` suffix) can silently break the match. Re-check such rules after a
  bump.
- **Non-Go / non-eBPF packages.** If your target has no Go modules, drop the
  `goModules` override and `vendorHash`; if it has no kernel module, drop the
  `linuxKernel.packagesFor` rewrite. The `namedSrc` protoc-dir trap is the
  portable core.
