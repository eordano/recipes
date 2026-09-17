{
  lib,
  stdenv,
  fetchFromGitHub,

  owner ? "ipverse",
  repo ? "rir-ip",
  rev ? "7c8ed361db346baac03fcaa0d2965c1a12050d8e",
  sha256 ? "sha256-jG9FVzTGgo7WSq/Dk+pqQiwu5c2UttS6TBrovTF56bU=",

  version ? "2026-03-08",
}:

stdenv.mkDerivation {
  pname = "geoip-country-lists";
  inherit version;

  src = fetchFromGitHub {
    inherit
      owner
      repo
      rev
      sha256
      ;
  };

  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/geoip-country-lists
    cp -r country/* $out/share/geoip-country-lists/

    runHook postInstall
  '';

  meta = with lib; {
    description = "Country-specific IP address lists for firewall configurations";
    longDescription = ''
      Per-country IPv4/IPv6 CIDR allocation lists derived from the Regional
      Internet Registries, packaged as a build-time Nix derivation so that
      firewall-by-country rulesets are reproducible and content-addressed
      rather than fetched at runtime.
    '';
    homepage = "https://github.com/ipverse/rir-ip";
    license = licenses.mit;
    platforms = platforms.all;
    maintainers = [ ];
  };
}
