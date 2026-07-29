# geoip-country-lists
#
# Pin a public RIR (Regional Internet Registry) IP-allocation repo as a
# build-time, content-hashed Nix derivation. The output is a directory of
# per-country IPv4/IPv6 CIDR lists that firewall / fail2ban / ipset configs
# can read from the store, so a "block/allow by country" ruleset is fully
# reproducible instead of depending on a runtime download.
#
# Usage as a package:
#
#     pkgs.callPackage ./geoip-country-lists { }
#
# Usage as an overlay (see ./overlay.nix for the tiny wrapper):
#
#     nixpkgs.overlays = [ (import ./geoip-country-lists/overlay.nix) ];
#     # then reference pkgs.geoip-country-lists anywhere
#
# The build output layout is:
#
#     $out/share/geoip-country-lists/<cc>/ipv4-aggregated.txt
#     $out/share/geoip-country-lists/<cc>/ipv6-aggregated.txt
#
# where <cc> is a lowercase ISO 3166-1 alpha-2 country code. The
# "-aggregated" files are route-summarized (fewer, larger CIDRs) which keeps
# ipset/nftables sets small; there are also non-aggregated variants in the
# upstream tree if you want the raw prefixes.
#
# To update: bump `rev` to a newer commit of ipverse/rir-ip, set `sha256` to
# lib.fakeHash, build once, and copy the real hash Nix prints back in. Because
# the hash is baked into the derivation, every machine that imports this gets
# byte-identical lists — the whole point of doing it at build time.

{
  lib,
  stdenv,
  fetchFromGitHub,

  # Pin of the upstream RIR IP data repo. Override these to move to a newer
  # snapshot (or to point at a mirror/fork with the same `country/` layout).
  owner ? "ipverse",
  repo ? "rir-ip",
  rev ? "7c8ed361db346baac03fcaa0d2965c1a12050d8e",
  sha256 ? "sha256-jG9FVzTGgo7WSq/Dk+pqQiwu5c2UttS6TBrovTF56bU=",

  # Version label — informational only; use the upstream snapshot date.
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

  # It's pure data — nothing to compile.
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
