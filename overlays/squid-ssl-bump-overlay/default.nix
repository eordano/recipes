# squid-ssl-bump-overlay
#
# Rebuild Squid with OpenSSL and the SSL-bump certificate generator/validator,
# which the nixpkgs default Squid ships WITHOUT.
#
# Three traps this overlay works around:
#
#   1. SSL-bump is a configure-time feature. You must add three flags:
#        --with-openssl                       point at the OpenSSL dev tree
#        --enable-security-cert-generators    build security_file_certgen
#        --enable-security-cert-validators    build the on-the-fly validator
#      Without these, `ssl_bump` / `sslcrtd_program` in squid.conf will fail
#      at runtime because the helper binaries were never built.
#
#   2. This build does NOT produce a working autotools `make install`, so the
#      default installPhase leaves you with an empty (or broken) $out. The
#      binaries and assets are copied by hand out of the build tree. The
#      `tree -la .` line is left in on purpose -- if a path below changes in a
#      future Squid release, the build log shows you the real layout so you
#      can fix the `cp` lines.
#
#   3. nixpkgs marks Squid with `meta.knownVulnerabilities`, which makes the
#      derivation refuse to evaluate. Overriding to build a patched/rebuilt
#      Squid does not clear that list, so you must reset it yourself:
#        meta.knownVulnerabilities = [ ];
#      Only do this when you have a reason to (you are running a fixed
#      version, or accept the risk on an internal box) -- you are opting out
#      of nixpkgs' block, so make sure your Squid is actually current.
#
# Usage: add to nixpkgs.overlays (or import as `final: prev:`). The result is
# a `squid` package with the bump helpers under $out/libexec, ready to point
# `sslcrtd_program` at $out/libexec/security_file_certgen.

final: prev:
let
  # Bumping nixpkgs may bring a Squid with NEW CVEs that the reset below would
  # silently clear. Fail loudly instead: re-check meta.knownVulnerabilities on
  # the new version, then update this pin.
  expectedSquidVersion = "7.6";
in
{
  squid =
    assert final.lib.assertMsg (prev.squid.version == expectedSquidVersion) ''
      squid-ssl-bump-overlay: nixpkgs squid is ${prev.squid.version}, expected ${expectedSquidVersion}.
      This overlay clears meta.knownVulnerabilities; re-check the new version's
      CVE status, then update expectedSquidVersion.'';
    prev.squid.overrideAttrs (oldAttrs: {
      pname = "squid";

      configureFlags = (oldAttrs.configureFlags or [ ]) ++ [
        "--with-openssl=${final.openssl.dev}"
        "--enable-security-cert-generators"
        "--enable-security-cert-validators"
      ];

      # This build produces no usable `make install`; copy artifacts by hand.
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin $out/libexec $out/etc $out/share
        # Left in deliberately: shows the real build-tree layout in the log so
        # the cp paths below can be re-checked if a Squid release moves things.
        ${prev.tree}/bin/tree -la .
        cp src/squid $out/bin
        cp src/unlinkd $out/libexec
        cp src/security/cert_generators/file/security_file_certgen $out/libexec/security_file_certgen
        cp src/mime.conf.default $out/etc/mime.conf
        cp -r icons $out/share
        cp -r errors $out/share
        runHook postInstall
      '';

      buildInputs = (oldAttrs.buildInputs or [ ]) ++ [ final.openssl ];
      nativeBuildInputs = (oldAttrs.nativeBuildInputs or [ ]) ++ [ final.pkg-config ];

      # nixpkgs blocks Squid via knownVulnerabilities; reset so the derivation
      # evaluates. Only keep this if you are actually running a fixed version.
      meta.knownVulnerabilities = [ ];
    });
}
