# Tiny overlay wrapper: exposes the package as `pkgs.geoip-country-lists`.
#
#     nixpkgs.overlays = [ (import ./geoip-country-lists/overlay.nix) ];
#
final: _prev: {
  geoip-country-lists = final.callPackage ./default.nix { };
}
