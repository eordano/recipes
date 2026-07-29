# aarch64-native-webassets-overlay
#
# Source arch-agnostic web packages (static HTML/JS/CSS assets) from a freshly
# imported *native* x86_64 pkgs when their build itself SIGILLs under qemu-user
# on an aarch64 builder.
#
# The trap: packages like element-web / jitsi-meet emit platform-independent
# static assets, but the *build* runs webpack + the V8 JIT. Under qemu-user
# emulation the JIT emits host instructions the emulator can't execute, so the
# build dies with "uncaught target signal 4 (Illegal instruction)" (SIGILL).
# Because the OUTPUT is arch-agnostic, the natively-built x86_64 derivation is a
# byte-for-byte valid substitute on aarch64 — and building it natively means the
# emulator never runs the JS toolchain at all.
#
# Usage — this file is a *function* returning a nixpkgs overlay. Call it with
# the list of attribute names to source natively, then add the result to your
# `overlays`/`nixpkgs.overlays`:
#
#     nixpkgs.overlays = [
#       (import ./aarch64-native-webassets-overlay { }) # defaults below
#     ];
#
#     # or pick your own packages:
#     nixpkgs.overlays = [
#       (import ./aarch64-native-webassets-overlay {
#         packages = [ "element-web" "jitsi-meet" ];
#       })
#     ];
#
# ORDERING TRAP: apply this overlay *first*, before any overlay that patches or
# depends on the listed packages. Once something references `element-web`, it
# pins the emulated build and this substitution can no longer take effect.
#
# `packages` : list of attribute names in pkgs to replace with their
#              natively-built x86_64 equivalents on aarch64-linux. Each must be
#              a package whose output is truly arch-independent (static web
#              assets) — do NOT list anything with native binaries in its
#              output, or you will ship x86_64 ELF onto an aarch64 host.
{ packages ? [ "element-web" ] }:

# Standard overlay signature. `final` is unused: we deliberately take the
# native derivations verbatim rather than letting them re-enter the aarch64
# fixpoint (which would just reintroduce the emulated build).
_final: prev:

prev.lib.optionalAttrs (prev.stdenv.hostPlatform.system == "aarch64-linux") (
  let
    # A fresh, independent x86_64 nixpkgs instantiation. `prev.path` is the
    # nixpkgs source tree backing the current pkgs, so this reuses the exact
    # same nixpkgs revision — only the target system differs. `config` is
    # carried over so allowUnfree / permittedInsecurePackages / etc. still hold.
    pkgsX86 = import prev.path {
      system = "x86_64-linux";
      config = prev.config;
    };
  in
  prev.lib.genAttrs packages (name: pkgsX86.${name})
)
