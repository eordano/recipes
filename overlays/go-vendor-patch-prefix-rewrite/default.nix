# go-vendor-patch-prefix-rewrite
#
# Apply an upstream patch to a Nix-vendored Go dependency.
#
# The trap this solves: an upstream patch is authored against the DEPENDENCY's
# own repo layout (e.g. "a/net/foo.go"), but once that dependency is vendored
# into your module it lives under a module-qualified path
# (e.g. "vendor/example.com/dep/net/foo.go"). The a//b/ prefixes in the patch
# therefore never match the vendor tree, and `patch` fails with
# "can't find file to patch". On top of that, the vendor directory produced by
# the Nix Go fetcher is READ-ONLY, so even a correctly-targeted patch fails to
# write.
#
# The fix, in order:
#   1. chmod -R +w the exact vendor subtree you touch (fetcher output is r/o).
#   2. sed-rewrite the a//b/ prefixes in the patch so they carry the vendor
#      module qualifier.
#   3. Feed the rewritten patch to `patch -d vendor -p1`.
#
# This file exposes a reusable helper `patchVendoredGoDep` (a shell snippet
# generator) plus an example overlay showing how to wire it into an
# overrideAttrs buildPhase. Import the overlay into nixpkgs, or copy the helper.

final: prev:

let
  # patchVendoredGoDep :: attrs -> string (shell)
  #
  # Emits a shell snippet that rewrites an upstream patch's path prefixes to the
  # vendored module layout and applies it. Call it inside a buildPhase/postPatch,
  # once per patch.
  #
  # Arguments:
  #   patch      : path to the upstream patch file (as authored against the dep).
  #   module     : the Go module import path the dep is vendored under, e.g.
  #                "example.com/foo" or "github.com/you/bar". This is the prefix
  #                that gets inserted between "a/"/"b/" and the in-repo path.
  #   subpath    : the path INSIDE the dependency repo that the patch touches,
  #                e.g. "net/http/". Used both for the sed rewrite and to
  #                scope the chmod. Keep the trailing slash.
  #   vendorDir  : vendor root, relative to the source. Defaults to "vendor".
  #
  # The rewrite turns:
  #   a/<subpath>  ->  a/<module>/<subpath>
  #   b/<subpath>  ->  b/<module>/<subpath>
  # so that `patch -d vendor -p1` resolves to vendor/<module>/<subpath>.
  patchVendoredGoDep =
    {
      patch,
      module,
      subpath,
      vendorDir ? "vendor",
    }:
    ''
      # 1. The Go fetcher's vendor tree is read-only; make the touched subtree writable.
      chmod -R +w ${vendorDir}/${module}/${subpath}

      # 2. Rewrite a//b/ prefixes to the vendored module layout, then apply.
      #    -p1 strips the leading a//b/ so paths resolve under ${vendorDir}/.
      sed 's|a/${subpath}|a/${module}/${subpath}|g;s|b/${subpath}|b/${module}/${subpath}|g' \
        ${patch} | patch -d ${vendorDir} -p1
    '';
in
{
  # Example: patch a vendored dependency inside a Go package build.
  #
  # Replace `example-go-package` with the attribute you are overriding, and the
  # patchVendoredGoDep arguments with your dependency's real module/subpath.
  #
  # The `if [ -f ... ]` guard keeps the build working if the patch is dropped
  # later (e.g. after an upstream bump makes it redundant) without editing here.
  example-go-package = prev.example-go-package.overrideAttrs (old: {
    buildPhase = ''
      # (env such as GOOS/GOARCH goes here if you cross-compile, e.g. wasm)

      if [ -f patches/my-upstream-fix.patch ]; then
        ${patchVendoredGoDep {
          patch = "patches/my-upstream-fix.patch";
          module = "example.com/somedep"; # the vendored module import path
          subpath = "internal/thing/"; # path inside the dep the patch touches
        }}
      fi

      go build -mod=vendor -o out ./cmd/tool
    '';
  });

  # Re-export the helper so downstream overlays can reuse it directly:
  #   inherit (pkgs) patchVendoredGoDep;
  inherit patchVendoredGoDep;
}
