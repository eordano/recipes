{
  lib,
  stdenv,
  fetchFromGitHub,
}:

# Package the ipverse/rir-ip country IP-range lists as a pinned, reproducible
# Nix derivation. Firewall / fail2ban / nginx geo rules can then reference
#   <out>/share/geoip-country-lists/<cc>/ipv4-aggregated.txt
#   <out>/share/geoip-country-lists/<cc>/ipv6-aggregated.txt
# from the store instead of fetching the lists live at runtime.
#
# Why a derivation and not a runtime curl:
#   - Reproducible: the ranges are pinned by `rev` + `sha256`, so a rebuild
#     yields byte-identical rules. A live fetch means your firewall silently
#     changes whenever upstream (or a mirror, or DNS) changes — untracked drift
#     that is invisible until it wrongly (un)blocks traffic.
#   - Offline / boot-safe: firewall rules that depend on a network fetch race
#     the very network they are meant to police. Store paths are present before
#     the interface comes up.
#   - Auditable: bumping the range set becomes a reviewable rev+hash change.
#
# The RIRs (ARIN, RIPE, APNIC, LACNIC, AFRINIC) publish delegation stats; the
# ipverse/rir-ip repo aggregates them per ISO-3166 alpha-2 country code. This
# is coarse, allocation-level geolocation — fine for "block/allow a whole
# country at the packet filter", NOT for city/ASN lookup (use a MaxMind mmdb
# for that).

stdenv.mkDerivation (finalAttrs: {
  pname = "geoip-country-lists";
  # Derived from the pinned `rev` via `finalAttrs`, so it can never drift out of
  # sync with the data: bumping the rev below bumps the version for free.
  version = finalAttrs.src.rev;

  src = fetchFromGitHub {
    owner = "ipverse";
    repo = "rir-ip";
    # Pin to a specific commit, not a branch/tag. To bump: pick a new rev, set
    # sha256 = lib.fakeSha256, build once, paste the "got:" hash back here.
    rev = "7c8ed361db346baac03fcaa0d2965c1a12050d8e";
    sha256 = "sha256-jG9FVzTGgo7WSq/Dk+pqQiwu5c2UttS6TBrovTF56bU=";
  };

  # Pure data — nothing to compile.
  dontBuild = true;
  dontConfigure = true;

  # The repo lays the lists out as country/<cc>/{ipv4,ipv6,ipv4-aggregated,
  # ipv6-aggregated}.txt. We expose the whole `country/` tree under a stable
  # share/ prefix so consumers can build the path from a lowercased ISO code.
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
