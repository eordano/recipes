# acme-dns01-wildcard

A thin NixOS module (`acmeCerts`) over `security.acme.certs` for issuing
**DNS-01 wildcard certificates** — with the one fix that makes them actually
work behind a **split-horizon / local-caching resolver**.

## The problem

DNS-01 is the only ACME challenge that can issue `*.example.com` wildcards. The
flow is: lego writes a `_acme-challenge.example.com` TXT record via your DNS
provider's API, then **waits for the record to propagate** before telling
Let's Encrypt to validate.

That wait is a DNS lookup — and lego does it through the **host's configured
resolver**. If that resolver is anything other than a plain public recursive
resolver, the check breaks:

- a **split-horizon** setup (internal unbound/dnsmasq, VPN resolver, Active
  Directory DNS) serves the *internal* view of the zone, which has no ACME TXT;
- a **caching** resolver may hold a stale negative answer;
- a resolver that shadows the public zone simply never sees the record.

lego then concludes the record "never propagated" and the issuance **times
out** — even though the TXT is live on the public authoritative nameservers the
whole time. This failure is maddening because the record is genuinely correct;
only the *checker's viewpoint* is wrong.

## The fix (the load-bearing trick)

Two lego flags, applied to every cert:

```
--dns.propagation-disable-ans
--dns.resolvers=ns1.provider.net:53,ns2.provider.net:53,127.0.0.1:53
```

- `--dns.propagation-disable-ans` disables lego's built-in "authoritative
  completion" pre-check.
- `--dns.resolvers=...` **pins the resolvers lego queries** for the TXT record
  to the zone's *real authoritative nameservers*. The propagation check now
  asks the servers that actually hold the record, bypassing the local/split
  view entirely.

**On the flag name.** Older writeups (and older versions of this module) use
`--dns.disable-cp`. lego now labels that one `(deprecated) use
dns.propagation-disable-ans instead`, and nixpkgs' own ACME module emits
`--dns.propagation-disable-ans` when `dnsPropagationCheck = false`. The two are
the same underlying toggle under two names, so this is a pure rename with **no
behaviour change** — nothing about issuance, propagation waiting, or resolver
pinning differs. This module emits the current name.

Note that the module never touches the native `dnsPropagationCheck` option to
achieve this: it hardcodes `dnsPropagationCheck = true` at the
`security.acme.certs` level and always drives the disable through its own
`extraLegoFlags`.

`dnsPropagationCheck` stays **on** — you still want lego to wait until the
record is visible before validation, or Let's Encrypt races ahead and fails.
The flags change *how* that check looks up the record, not *whether* it waits.

## Usage

Import the module and declare certs by primary domain:

```nix
{ config, ... }:
{
  imports = [ ./modules/acme-dns01-wildcard ];

  # ACME account email + TOS (standard NixOS ACME config)
  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@example.com";
  };

  acmeCerts."example.com" = {
    wildcard        = true;                     # issues example.com + *.example.com
    dnsProvider     = "digitalocean";           # any lego provider code
    credentialsFile = config.age.secrets.dns-token.path;
    resolvers = [
      "ns1.digitalocean.com:53"
      "ns2.digitalocean.com:53"
      "ns3.digitalocean.com:53"
      "127.0.0.1:53"
    ];
  };
}
```

The reverse proxy reads the result from `security.acme.certs."example.com"` as
usual (e.g. `services.nginx.virtualHosts."example.com".useACMEHost = "example.com"`).

## Options

Each `acmeCerts.<domain>` entry accepts:

| Option | Default | Purpose |
|---|---|---|
| `wildcard` | `false` | Add a `*.<domain>` SAN. |
| `extraDomainNames` | `[]` | Extra SANs on the same certificate. |
| `group` | `"nginx"` | Group that owns the cert files (so the proxy can read them). |
| `dnsProvider` | `"digitalocean"` | lego DNS provider code. |
| `credentialsFile` | *(required)* | Env file with the provider API token — wire from agenix/sops-nix/plain path. |
| `resolvers` | `[]` | Authoritative resolvers (`host:port`) lego queries for the TXT record. **Set this** when split-horizon is in play. |
| `disableCompletePropagationCheck` | `true` | Emit `--dns.propagation-disable-ans`. |
| `extraLegoFlags` | `[]` | Raw extra flags. |

## Notes / caveats

- **`credentialsFile` format is provider-specific.** It's passed straight to
  `security.acme.certs.<domain>.environmentFile`, so it must set the
  environment variables the chosen lego provider expects (e.g.
  `DO_AUTH_TOKEN=...` for DigitalOcean, `CF_DNS_API_TOKEN=...` for Cloudflare).
- **Get the provider code right.** `dnsProvider` is a lego provider code, not a
  friendly name; check lego's provider list.
- **Not just wildcards.** The resolver-pinning fix helps *any* DNS-01 issuance
  on a host with a non-public resolver, wildcard or not.
- **If you have no split-horizon**, leaving `resolvers = []` and relying on the
  system resolver is fine — but pinning authoritative resolvers is harmless and
  makes issuance robust against later resolver changes.
- This module is secret-manager agnostic: it stores no token names and makes no
  provider assumptions. Every cert brings its own credentials, provider and
  resolvers.
