{
  lib,
  stdenv,
  fetchFromGitHub,
}:
stdenv.mkDerivation {
  pname = "geoip-countrylist";
  version = "2025-12-02";

  src = fetchFromGitHub {
    owner = "ipverse";
    repo = "rir-ip";
    rev = "43421d2cb13ed74d3ce47624306d6104f6202833";
    sha256 = "sha256-zs7fawiKBMneFB2qJXWUtYc037fb24eir1TZCPwEN3w=";
  };

  dontBuild = true;

  installPhase = ''
    mkdir -p $out/share/geoip-countrylist
    cp -r country/* $out/share/geoip-countrylist/
  '';

  meta = with lib; {
    description = "Country-specific IP address lists for firewall configurations";
    homepage = "https://github.com/ipverse/rir-ip";
    license = licenses.mit;
    platforms = platforms.all;
    maintainers = [ ];
  };
}
