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
    rev = "7c8ed361db346baac03fcaa0d2965c1a12050d8e";
    sha256 = "sha256-jG9FVzTGgo7WSq/Dk+pqQiwu5c2UttS6TBrovTF56bU=";
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
