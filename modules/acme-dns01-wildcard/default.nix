# acme-dns01-wildcard
#
# A thin `acmeCerts` wrapper over `security.acme.certs` that makes DNS-01
# wildcard certificates painless — and, crucially, makes lego's propagation
# check survive a split-horizon / local-caching resolver.
#
# The load-bearing trick lives in `extraLegoFlags`:
#
#   --dns.propagation-disable-ans  disable lego's own "authoritative nameserver"
#                                  completion pre-check (the modern flag; lego's
#                                  older `--dns.disable-cp` is now deprecated —
#                                  see the 2026-07-28 README note)
#   --dns.resolvers=...            pin the resolvers lego queries for the ACME
#                                  TXT record to the zone's real authoritative
#                                  nameservers (+ optionally 127.0.0.1)
#
# Without this, lego resolves the `_acme-challenge` TXT through the host's
# configured resolver. Behind split-horizon DNS (a local unbound/dnsmasq,
# a VPN resolver, or a caching resolver that shadows the public zone) that
# lookup either returns the internal view or a stale/empty answer, so lego
# concludes the record "never propagated" and the issuance times out — even
# though the TXT is live on the public authoritative servers. Pointing lego
# straight at the authoritative resolvers sidesteps the local view entirely.
#
# Import as a NixOS module, then declare certs by domain name:
#
#   acmeCerts."example.com" = {
#     wildcard        = true;                       # adds *.example.com
#     credentialsFile = config.age.secrets.dns-token.path;
#     resolvers       = [ "ns1.provider.net:53" "ns2.provider.net:53" ];
#   };
#
# This module intentionally carries no secret-name table and no provider
# assumptions: every cert names its own credentials file, DNS provider and
# authoritative resolvers. Wire the credentialsFile to whatever secret
# manager you use (agenix/sops-nix/plain path).

{ config, lib, ... }:

let
  cfg = config.acmeCerts;
in
{
  options.acmeCerts = lib.mkOption {
    description = ''
      Declarative DNS-01 certificates keyed by primary domain. Each entry is
      expanded into a `security.acme.certs.<domain>` with the split-horizon-safe
      lego flags applied.
    '';
    default = { };
    type =
      with lib.types;
      attrsOf (submodule {
        options = {
          wildcard = lib.mkOption {
            type = bool;
            default = false;
            description = "Add a `*.<domain>` SAN to the certificate.";
          };

          extraDomainNames = lib.mkOption {
            type = listOf str;
            default = [ ];
            example = [ "www.example.com" "api.example.com" ];
            description = "Additional Subject Alternative Names for the certificate.";
          };

          group = lib.mkOption {
            type = str;
            default = "nginx";
            description = ''
              Group that owns the issued certificate files. Defaults to the web
              server group so the reverse proxy can read them.
            '';
          };

          dnsProvider = lib.mkOption {
            type = str;
            default = "digitalocean";
            example = "cloudflare";
            description = ''
              lego DNS provider code used for the DNS-01 challenge. See the lego
              documentation for the full list of provider codes.
            '';
          };

          credentialsFile = lib.mkOption {
            type = path;
            example = "/run/secrets/dns-api-token.env";
            description = ''
              Path to the environment file holding the DNS provider's API
              credentials (passed to `security.acme.certs.<domain>.environmentFile`).
              Provide it from your secret manager of choice — e.g.
              `config.age.secrets.dns-token.path` (agenix),
              `config.sops.secrets.dns-token.path` (sops-nix), or a plain path.
            '';
          };

          resolvers = lib.mkOption {
            type = listOf str;
            default = [ ];
            example = [ "ns1.provider.net:53" "ns2.provider.net:53" "127.0.0.1:53" ];
            description = ''
              Authoritative resolvers lego should query for the ACME TXT record,
              as `host:port` entries. THE key setting: point these at the zone's
              real authoritative nameservers so the propagation check bypasses a
              local/split-horizon resolver that would otherwise return the wrong
              view and stall issuance. When empty, lego uses the system resolver
              (fine only when there is no split-horizon in play).
            '';
          };

          disableCompletePropagationCheck = lib.mkOption {
            type = bool;
            default = true;
            description = ''
              Pass lego's `--dns.propagation-disable-ans` to skip its built-in
              authoritative completion pre-check. Combined with a pinned
              `resolvers` list this is what keeps the propagation check from
              failing behind a local or split-horizon resolver. Leave enabled
              unless you have a reason not to.
            '';
          };

          extraLegoFlags = lib.mkOption {
            type = listOf str;
            default = [ ];
            description = "Additional raw flags appended to the lego invocation.";
          };
        };
      });
  };

  config.security.acme.certs = builtins.mapAttrs (domain: attrs: {
    inherit (attrs) group dnsProvider;
    environmentFile = attrs.credentialsFile;

    # Keep the propagation check ON — the wait is what prevents Let's Encrypt
    # from validating before the TXT exists. The propagation-disable-ans flag
    # + pinned resolvers below change *how* that check is performed, not whether.
    dnsPropagationCheck = true;

    extraDomainNames =
      (lib.optional attrs.wildcard "*.${domain}") ++ attrs.extraDomainNames;

    extraLegoFlags =
      (lib.optional attrs.disableCompletePropagationCheck "--dns.propagation-disable-ans")
      ++ (lib.optional (attrs.resolvers != [ ])
        "--dns.resolvers=${lib.concatStringsSep "," attrs.resolvers}")
      ++ attrs.extraLegoFlags;
  }) cfg;
}
