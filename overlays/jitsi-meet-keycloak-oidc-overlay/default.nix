{
  adapterSrc,

  nativeSystem ? "x86_64-linux",
}:

_final: prev:
let
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
      addOidc prev.jitsi-meet
    else
      addOidc
        (import prev.path {
          system = nativeSystem;
          inherit (prev) config;
        }).jitsi-meet;
}
