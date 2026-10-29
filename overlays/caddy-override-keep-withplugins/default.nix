final: prev:
let
  goToolchain = prev.go.overrideAttrs (_: rec {
    version = "1.26.8";
    src = prev.fetchurl {
      url = "https://go.dev/dl/go${version}.src.tar.gz";
      hash = "sha256-Tjm5jkL5RvoFrIvFtxh335fb23y7Gnd7VBZnrXEX/S4=";
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
