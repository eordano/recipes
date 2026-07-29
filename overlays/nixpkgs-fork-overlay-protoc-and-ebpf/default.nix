# nixpkgs-fork-overlay-protoc-and-ebpf
#
# Rebuild a nixpkgs package (here: a Go daemon + PyQt UI + eBPF kernel module,
# modelled on `opensnitch`) against a *vendored fork* of its source, WITHOUT
# repackaging it from scratch. You inherit nixpkgs' build recipe and swap only
# `src`, `version`, `vendorHash`, and drop the now-non-applying patch set.
#
# Two traps this pattern exists to solve:
#
#   1. A git-archived source tarball lacks any *gitignored generated output*
#      dirs (e.g. protoc output). A `runCommand` wrapper must `mkdir -p` those
#      dirs up front, or protoc fails "No such file or directory" during the
#      build. That is the whole reason the `namedSrc` wrapper exists.
#
#   2. `overrideAttrs` on the top-level derivation cannot reach a *kernel-module
#      subpackage* built through `linuxKernel.packagesFor`. To strip patches
#      from the eBPF object too, you must extend `linuxKernel.packagesFor` so
#      every kernel's build of that subpackage also gets `patches = [ ]`.
#
# ---------------------------------------------------------------------------
# Usage (as a flake overlay):
#
#   # flake.nix
#   inputs.myfork.url = "github:you/your-fork";  # or path:./vendor/your-fork
#   ...
#   overlays.default = import ./overlays/nixpkgs-fork-overlay-protoc-and-ebpf {
#     forkSrc     = inputs.myfork;
#     version     = "1.9.0";                      # the FORK's own version string
#     vendorHash  = "sha256-AAAA...=";            # recompute when go.mod/go.sum change
#     # optional knobs below have sensible defaults:
#     # pname          = "opensnitch";
#     # uiPname        = "opensnitch-ui";
#     # ebpfPname      = "opensnitch-ebpf";
#     # protocOutputDirs = [ "daemon/ui/protocol" "ui/opensnitch/proto" ];
#     # uiSubdir       = "ui";
#     # doCheck        = false;
#   };
#
# Then apply the overlay in your nixpkgs instantiation and use the rebuilt
# package(s) as normal.
#
# `vendorHash` note: any change to the fork's go.mod / go.sum (i.e. re-vendoring
# to a rev with different Go deps) requires recomputing this, or the goModules
# build fails with a hash mismatch. Set it to
# `lib.fakeHash` once to let Nix print the correct value, then paste it back.
# ---------------------------------------------------------------------------

{
  # The vendored fork source (a flake input, path:, fetchFromGitHub result, ...).
  forkSrc,

  # The fork's own version string. This is the FORK's number, not an upstream
  # tag — `nix flake update` won't advance it; it moves only when you re-vendor.
  version,

  # Go module vendor hash. Recompute whenever the fork's go.mod/go.sum change.
  vendorHash,

  # nixpkgs attribute names of the derivations being rebuilt. Defaults match the
  # opensnitch family (the worked example below); override for your package.
  pname ? "opensnitch",
  uiPname ? "opensnitch-ui",
  ebpfPname ? "opensnitch-ebpf",

  # Gitignored generated-output dirs (relative to the source root) that must
  # exist before the build's codegen step (e.g. protoc) runs. A git-archived
  # checkout will not contain them.
  protocOutputDirs ? [
    "daemon/ui/protocol"
    "ui/opensnitch/proto"
  ],

  # Subdirectory within the source that the UI derivation builds from.
  uiSubdir ? "ui",

  # Whether to run the daemon's test suite. Left off by default because the
  # upstream test suite here has a known flaky race; flip to true if yours is
  # reliable.
  doCheck ? false,
}:

final: prev:

let
  # Wrap the raw fork source so that:
  #   - it has a stable, descriptive store name, and
  #   - the gitignored codegen output dirs exist BEFORE the build runs.
  #
  # A `git archive` / vendored checkout is tracked-source-only, so any dir that
  # upstream lists in .gitignore (typical for protoc output) is simply absent.
  # protoc then fails "No such file or directory" when it tries to write into
  # them. Creating them here is the entire point of this wrapper — don't strip it.
  namedSrc = prev.runCommand "${pname}-${version}-source" { } ''
    cp -r ${forkSrc.outPath or forkSrc} $out
    chmod -R u+w $out
    mkdir -p ${prev.lib.concatMapStringsSep " " (d: "$out/${d}") protocOutputDirs}
  '';

  # Strip patches from the eBPF kernel-module subpackage. This override lives at
  # the linuxKernel.packagesFor level because that subpackage is built per-kernel
  # and is NOT reachable from an `overrideAttrs` on the top-level derivation.
  dropEbpfPatches = lpFinal: lpPrev: {
    ${ebpfPname} = lpPrev.${ebpfPname}.overrideAttrs { patches = [ ]; };
  };
in
{
  # The Go daemon. Rebuild against the fork src; drop nixpkgs' patches (written
  # against the older upstream tree, they no longer apply); re-vendor Go deps.
  ${pname} = prev.${pname}.overrideAttrs (old: {
    inherit version doCheck;
    src = namedSrc;
    patches = [ ];
    goModules = old.goModules.overrideAttrs {
      inherit vendorHash;
      src = namedSrc;
    };
  });

  # The PyQt UI. Same src/version, build from the UI subdir, drop patches.
  ${uiPname} = prev.${uiPname}.overrideAttrs (old: {
    inherit version;
    src = namedSrc;
    sourceRoot = "${namedSrc.name}/${uiSubdir}";
    patches = [ ];
  });

  # Rewrite packagesFor so EVERY kernel's eBPF subpackage is built patch-free.
  # overrideAttrs on the top-level derivation above cannot reach this.
  linuxKernel = prev.linuxKernel // {
    packagesFor = kernel: (prev.linuxKernel.packagesFor kernel).extend dropEbpfPatches;
  };
}
