final: prev:
let
  goToolchain = prev.go.overrideAttrs (_: rec {
    version = "1.26.2";
    src = prev.fetchurl {
      url = "https://go.dev/dl/go${version}.src.tar.gz";
      hash = "sha256-LpHrtpR6lulDb7KzkmqIAu/mOm03Xf/sT4Kqnb1v1Ds=";
    };
  });

  buildGoModule' = prev.buildGoModule.override { go = goToolchain; };

  caddyBase = prev.caddy.override { buildGoModule = buildGoModule'; };
in
{
  caddy = caddyBase.overrideAttrs (old: {
    passthru = (old.passthru or { }) // {
      withPlugins = final.callPackage "${prev.path}/pkgs/by-name/ca/caddy/plugins.nix" {
        inherit (final) caddy;
        go = goToolchain;
      };
    };
  });
}
