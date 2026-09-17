final: prev:
let
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

      meta.knownVulnerabilities = [ ];
    });
}
