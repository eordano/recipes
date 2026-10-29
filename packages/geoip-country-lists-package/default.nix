{
  lib,
  stdenv,
  fetchFromGitHub,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "geoip-country-lists";
  version = finalAttrs.src.rev;

  src = fetchFromGitHub {
    owner = "ipverse";
    repo = "rir-ip";
    rev = "1e828cb4e413cf851bcb02e8b302174c0d488442";
    sha256 = "sha256-9YaZBDd8pIYyWhdzNaQfY3zaJBwlBlXYeLXGaaxNmw4=";
  };

  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/geoip-country-lists"
    cp -r country/* "$out/share/geoip-country-lists/"
    runHook postInstall
  '';

  meta = with lib; {
    description = "Per-country IPv4/IPv6 allocation lists (ipverse/rir-ip) for firewall rules";
    homepage = "https://github.com/ipverse/rir-ip";
    license = licenses.mit;
    platforms = platforms.all;
    maintainers = [ ];
  };
})
