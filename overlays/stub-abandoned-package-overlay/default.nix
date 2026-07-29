# Stub an abandoned package so a dangling closure reference resolves without
# building anything.
#
# Problem: your system/user closure still references a package that no longer
# builds (upstream-abandoned, or it FTBFS on your nixpkgs pin), even though you
# never install it directly — it gets pulled in transitively (e.g. a terminfo
# aggregation that lists every terminal emulator). Chasing down every consumer
# is tedious and fragile. Instead, replace the package with an empty stub
# derivation so the reference resolves to something that "builds" instantly.
#
# The key trap: a package attribute is often used both as a derivation AND
# via its sub-attributes (e.g. `pkg` for the binary, `pkg.terminfo` for its
# terminfo files). A plain `runCommand` stub only satisfies the first. Use the
# `//` operator to graft the extra sub-attributes onto the stub so BOTH kinds
# of reference resolve.
#
# Two ways to use this file:
#
#   1. Import the helper and build a stub overlay for your package(s):
#
#        let stub = import ./default.nix;
#        in {
#          nixpkgs.overlays = [
#            (stub {
#              name = "termite";
#              # sub-attributes that consumers also reference; the value is the
#              # relative path(s) to create inside the stub's $out.
#              subAttrs.terminfo = [ "share/terminfo" ];
#            })
#          ];
#        }
#
#   2. Copy the tiny overlay at the bottom of this file and hardcode your
#      package name — that is all the original real-world use amounted to.

# ── The helper ──────────────────────────────────────────────────────────────
#
# stub { name; subAttrs ? {}; } -> overlay (final: prev: { ... })
#
#   name     : attribute name of the abandoned package to replace.
#   subAttrs : attrset mapping sub-attribute name -> list of relative dirs to
#              create inside that sub-attribute's $out. Each entry becomes an
#              empty derivation grafted onto the stub via `//`.

{ name, subAttrs ? { } }:

final: prev:

let
  # An empty derivation that just makes an (optionally populated) $out.
  emptyDrv = drvName: dirs:
    prev.runCommand drvName { } (
      if dirs == [ ]
      then "mkdir -p $out"
      else "mkdir -p " + prev.lib.concatMapStringsSep " "
        (d: "$out/" + d) dirs
    );

  # Build the sub-attribute stubs, e.g. { terminfo = <drv>; }.
  subDrvs = prev.lib.mapAttrs
    (attr: dirs: emptyDrv "${name}-${attr}-stub" dirs)
    subAttrs;
in
{
  # `//` grafts the sub-attribute stubs onto the top-level stub derivation, so
  # both `pkgs.${name}` and `pkgs.${name}.<subAttr>` resolve.
  ${name} = emptyDrv "${name}-stub" [ ] // subDrvs;
}

# ── Minimal copy-paste version (no helper) ───────────────────────────────────
#
# If you only need to stub one package with one sub-attribute, the whole thing
# is just this overlay — drop it straight into `nixpkgs.overlays`:
#
#   final: prev: {
#     termite = prev.runCommand "termite-stub" { } "mkdir -p $out" // {
#       terminfo = prev.runCommand "termite-terminfo-stub" { } ''
#         mkdir -p $out/share/terminfo
#       '';
#     };
#   }
