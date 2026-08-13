# squid-ssl-bump-overlay

Rebuild Squid with OpenSSL and the SSL-bump certificate generator/validator.
The Squid that nixpkgs ships is built **without** SSL-bump, so
`ssl_bump` / `sslcrtd_program` directives in your `squid.conf` will not work --
the helper binaries they call were never compiled.

## The problem

SSL-bump (Squid's TLS interception / "peek and splice") needs three things
that are all off by default in nixpkgs:

- Squid linked against OpenSSL.
- The `security_file_certgen` helper (mints per-site certs on the fly).
- The certificate validator.

All three are **configure-time** features. You cannot turn them on with
runtime config; the package has to be rebuilt.

## The traps

1. **Three configure flags.** You must add `--with-openssl`,
   `--enable-security-cert-generators`, and `--enable-security-cert-validators`.
   Miss any and the corresponding helper is silently absent.

2. **No working `make install`.** This Squid build does not produce a usable
   autotools install target, so the default `installPhase` gives you an empty
   or broken `$out`. The overlay copies the binaries and assets out of the
   build tree by hand. A `tree -la .` is left in the install phase on purpose:
   if a future Squid release moves a path, the build log shows the real layout
   so you can correct the `cp` lines.

3. **`meta.knownVulnerabilities` blocks evaluation.** nixpkgs flags Squid with
   known vulnerabilities, which makes the derivation refuse to evaluate.
   `overrideAttrs` does not clear that, so the overlay resets it with
   `meta.knownVulnerabilities = [ ]`. This is opting out of a safety block --
   keep it only when you are genuinely running a current/fixed Squid, or you
   accept the risk on an isolated box.

## Usage

Add the overlay to `nixpkgs.overlays`:

```nix
{
  nixpkgs.overlays = [ (import ./overlays/squid-ssl-bump-overlay/default.nix) ];
}
```

or drop the `final: prev:` function straight into your overlay list. The
result is a `squid` package with the bump helpers under `$out/libexec`. Point
your `squid.conf` at the certgen helper, e.g.:

```
sslcrtd_program /run/current-system/sw/libexec/security_file_certgen -s /var/cache/squid/ssl_db -M 4MB
```

(adjust the path to wherever the built `squid` package lands -- under NixOS's
`services.squid` it is on the service's `PATH`).

You still need to generate a CA certificate/key for Squid to sign with and
distribute that CA to the clients whose traffic you intercept -- that part is
your deployment's concern and is not covered here.

## Caveats

- Clearing `knownVulnerabilities` means you are on your own for CVE tracking on
  Squid. To keep that opt-out from silently swallowing *new* CVEs, the overlay
  `assert`s the Squid version it was audited against
  (`expectedSquidVersion`) -- a nixpkgs bump that changes the Squid version
  fails evaluation loudly. Re-check the new version's CVE status, then update
  the pin in `default.nix`.
- **This is an overlay, so it redefines `pkgs.squid` machine-wide.** Every
  consumer of `squid` in your configuration -- not just the service you built it
  for -- gets this rebuild with the CVE block cleared, and the reset is
  unconditional: a future nixpkgs bump that adds a *new* Squid CVE clears that
  too, silently. Prefer scoping the rebuild to the one service that needs it, or
  pin the accepted version (e.g. `nixpkgs.config.permittedInsecurePackages`) so a
  version change forces you to re-acknowledge the risk.
- The hand-copied paths (`src/squid`, `src/security/cert_generators/file/...`,
  etc.) track Squid's build-tree layout. If the build breaks after a version
  bump, read the `tree` output in the log and fix the `cp` lines.
- TLS interception has real privacy and security implications. Only bump
  traffic you are authorized to inspect.
