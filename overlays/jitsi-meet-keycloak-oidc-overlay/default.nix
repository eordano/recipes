# jitsi-meet-keycloak-oidc-overlay
#
# A Nixpkgs overlay that bolts a Keycloak / OIDC SSO adapter into jitsi-meet's
# static web output via `overrideAttrs`, and dodges a qemu-user webpack crash
# on non-native builders by reusing the natively-built derivation.
#
# It is a *curried* overlay: import it with your arguments first, then hand the
# result to `nixpkgs.overlays`.
#
#   nixpkgs.overlays = [
#     (import ./jitsi-meet-keycloak-oidc-overlay {
#       adapterSrc = ./my-jitsi-oidc-adapter;   # your OIDC adapter tree
#       # nativeSystem = "x86_64-linux";        # default; the arch you can build natively
#     })
#   ];
#
# See README.md for what `adapterSrc` must contain and the traps involved.

{
  # Path to your OIDC adapter source tree. Its layout is merged into the
  # jitsi-meet output like so:
  #   ${adapterSrc}/*.ts          -> copied into $out/oidc-adapter/
  #   ${adapterSrc}/jitsi-meet/*  -> merged into $out/ (static HTML shims etc.)
  #
  # This is intentionally *your* tree, not a vendored copy: point it at a
  # checkout of an upstream jitsi <-> Keycloak OIDC adapter (several exist),
  # or at your own fork. Keeping it a parameter avoids re-vendoring a
  # third-party, separately-licensed codebase inside this overlay.
  adapterSrc,

  # The system whose *natively built* jitsi-meet is reused when the host
  # platform cannot run the webpack build under emulation. This must be a
  # platform your builder can produce natively (native builder or a binary
  # cache), otherwise you just move the emulation problem, you don't solve it.
  nativeSystem ? "x86_64-linux",
}:

# Standard overlay signature. `prev` is the un-overlaid package set; we don't
# need `final` here.
final: prev:
let
  # Bolt the adapter's static assets into a jitsi-meet derivation's output.
  # jitsi-meet ships plain static web assets, so appending files in a late
  # install phase is enough — no rebuild of the webpack bundle is required.
  addOidc =
    jm:
    jm.overrideAttrs (old: {
      installPhase = (old.installPhase or "") + ''
        mkdir -p $out/oidc-adapter
        cp -r ${adapterSrc}/*.ts $out/oidc-adapter/
        cp -r ${adapterSrc}/jitsi-meet/* $out/
      '';
    });
in
{
  jitsi-meet =
    if prev.stdenv.hostPlatform.system == nativeSystem then
      # Native host: just override the package set's own jitsi-meet.
      addOidc prev.jitsi-meet
    else
      # Non-native host (e.g. aarch64 building for x86_64-native tooling):
      #
      # jitsi-meet's *output* is platform-independent static web assets, but its
      # webpack build crashes under qemu-user emulation — the V8 JIT emits an
      # instruction qemu-user can't translate and the process dies with
      # "uncaught target signal 4 (Illegal instruction)".
      #
      # Since the output is arch-independent, we sidestep emulation entirely:
      # re-import nixpkgs (pinned via `prev.path`) *for the native system* and
      # reuse that natively-built jitsi-meet, then bolt the adapter onto it.
      # The result is still a valid derivation for the current host because the
      # files it contains are just static assets.
      addOidc
        (import prev.path {
          system = nativeSystem;
          config = prev.config;
        }).jitsi-meet;
}
