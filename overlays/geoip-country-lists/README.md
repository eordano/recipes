# geoip-country-lists

Pin a public RIR IP-allocation dataset as a **build-time, content-hashed Nix
derivation** so that "firewall by country" allow/block rulesets are
reproducible — instead of fetching the IP lists at runtime.

## The problem

If you want to allow or block traffic per country (with `ipset`, `nftables`,
`fail2ban`, etc.), you need the set of IP ranges assigned to each country. The
common approaches all fetch that data at *runtime*:

- a boot/activation script that `curl`s a country-IP list off some website,
- a cron job that regenerates ipsets from a downloaded file,
- a GeoIP database that a daemon reloads periodically.

Every one of those makes your firewall depend on a network fetch that:

- can fail or hang at boot (the firewall comes up wrong, or not at all),
- can silently change under you (the upstream file updates, your rules shift),
- differs machine-to-machine (each host downloads at a different moment),
- isn't captured by your config's hash, so "the same config" ≠ "the same rules".

## The insight

The [`ipverse/rir-ip`](https://github.com/ipverse/rir-ip) repo already
publishes per-country IPv4/IPv6 CIDR lists, aggregated from the Regional
Internet Registries, as plain text files in a `country/<cc>/` tree. So you can
just **`fetchFromGitHub` it at build time and pin the commit + hash**.

That flips every downside above:

- No network access at boot — the lists are already in the Nix store.
- The exact data is pinned by `rev` + `sha256`; nothing changes until you
  deliberately bump it.
- Every machine importing this derivation gets **byte-identical** lists.
- The list content is part of your config's closure hash — reproducible.

Updating the data becomes an explicit, reviewable change (bump the rev), which
is exactly what you want for something that decides who can reach your box.

## Output layout

The derivation installs the country tree under a stable share path:

```
$out/share/geoip-country-lists/<cc>/ipv4-aggregated.txt
$out/share/geoip-country-lists/<cc>/ipv6-aggregated.txt
```

- `<cc>` is a **lowercase** ISO 3166-1 alpha-2 code (`us`, `de`, `fr`, …).
- The `*-aggregated.txt` files are route-summarized — far fewer, larger CIDRs,
  which keeps the resulting ipset/nftables sets small and fast to load. The
  upstream tree also has non-aggregated variants if you need raw prefixes.
- Each file has `#` comment lines; strip them (`grep -v '^#'`) before feeding
  the CIDRs into a tool.

## Usage

As a package:

```nix
pkgs.callPackage ./geoip-country-lists { }
```

As an overlay (adds `pkgs.geoip-country-lists`):

```nix
{
  nixpkgs.overlays = [ (import ./geoip-country-lists/overlay.nix) ];
}
```

### Example: build ipsets from the lists

A minimal sketch of consuming the store path in a firewall script. This reads
the pinned files and loads one ipset per country — no runtime download:

```nix
{ pkgs, ... }:
let
  lists = pkgs.geoip-country-lists;
  countries = [ "us" "de" "fr" ];          # lowercase = the on-disk dir names
  base = "${lists}/share/geoip-country-lists";
in
{
  networking.firewall.extraCommands = ''
    ${pkgs.lib.concatMapStrings (cc: ''
      ${pkgs.ipset}/bin/ipset create -exist country_${cc} hash:net family inet
      ${pkgs.ipset}/bin/ipset flush country_${cc}
      if [ -f "${base}/${cc}/ipv4-aggregated.txt" ]; then
        ${pkgs.gnugrep}/bin/grep -v '^#' "${base}/${cc}/ipv4-aggregated.txt" \
          | while read -r cidr; do
              ${pkgs.ipset}/bin/ipset add -exist country_${cc} "$cidr"
            done
      fi
    '') countries}

    # ... then match with: iptables -m set --match-set country_us src -j ACCEPT
  '';
}
```

### Arguments

Every part of the pin is an overridable `callPackage` argument.

| Argument | Default | Purpose |
| --- | --- | --- |
| `owner` / `repo` | `ipverse` / `rir-ip` | Upstream repo; point at a mirror or fork with the same `country/` layout. |
| `rev` | a pinned commit | The snapshot. Bump this to move the data forward. |
| `sha256` | hash of that commit | Must be recomputed whenever `rev` changes. |
| `version` | `"2026-03-08"` | Informational label only; use the upstream snapshot date. |

## Updating the pinned snapshot

1. Set `rev` to a newer commit of `ipverse/rir-ip`.
2. Set `sha256 = pkgs.lib.fakeHash;` (or override the `sha256` arg to that).
3. Build once; Nix errors with the real hash — paste it back into `sha256`.
4. Bump `version` to the snapshot date for clarity.

Because the hash is baked in, this is the *only* moment the rules can change —
which is the guarantee the whole recipe exists to give you.

## Caveats

- **RIR data is coarse and drifts.** Country → IP mapping is best-effort:
  ranges get reallocated, transferred between regions, and routed elsewhere by
  the holder. Treat it as a broad filter, not an authority. Combine
  allow/block-by-country with connection-state rules (accept
  `ESTABLISHED,RELATED`) and explicit exceptions for your own
  loopback/private/VPN ranges so you don't lock yourself out.
- **Country codes are case-sensitive on disk.** The directories are lowercase;
  normalize user input (`toLower`) before building the store path.
- **Aggregated ≠ complete-per-IP.** Aggregation merges adjacent prefixes; it's
  the right default for firewalls but don't treat a single CIDR as an exact
  organizational boundary.
- The upstream data is MIT-licensed; this recipe just repackages it.
