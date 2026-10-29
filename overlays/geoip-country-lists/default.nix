{
  lib,
  stdenv,
  fetchFromGitHub,

  owner ? "ipverse",
  repo ? "rir-ip",
  rev ? "1e828cb4e413cf851bcb02e8b302174c0d488442",
  sha256 ? "sha256-9YaZBDd8pIYyWhdzNaQfY3zaJBwlBlXYeLXGaaxNmw4=",

  version ? "2026-10-01",
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
