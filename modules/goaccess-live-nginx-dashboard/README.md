# goaccess-live-nginx-dashboard

A NixOS module that serves [GoAccess](https://goaccess.io/)'s **real-time HTML
log dashboard** over nginx, updated live in the browser over a WebSocket, and
gated to an IP allow-list. It builds GoAccess with MaxMind GeoIP support
explicitly enabled and optionally keeps the GeoLite2 databases fresh.

## What it solves

GoAccess can tail an nginx access log and render a live HTML dashboard (top
URLs, visitors, geo map, status codes, …) that updates in place via a
WebSocket. Wiring that up cleanly on NixOS means gluing together a custom
package build, a systemd service, an nginx vhost with a WebSocket proxy, and
GeoIP data. This module packages all of it behind a handful of options.

The dashboard exposes **full visitor logs**, so it is never public: both the
static page (`/`) and the WebSocket (`/ws`) are locked to an `allowedIPs`
allow-list, with `deny all` behind it.

## The two traps this exists to fix

### 1. GoAccess must be built with MaxMind MMDB support

Without `--enable-geoip=mmdb` and `libmaxminddb`, GoAccess simply ignores the
`.mmdb` files and the geo map comes up empty. Rather than fork the package, the
module `overrideAttrs` `pkgs.goaccess` to append `--enable-geoip=mmdb` and
`--enable-utf8` and add `libmaxminddb` to `buildInputs`.

Note the history here, because the rationale has shifted: this override was
originally load-bearing, because nixpkgs' `goaccess` was built without MMDB
support. Current nixpkgs enables it by default (the package takes
`withGeolocation ? true` and already passes both flags), so on an up-to-date
nixpkgs the override is redundant rather than required. It is kept because it is
harmless — duplicate `configure` flags are fine — and it keeps the module working
on older pins and on a `goaccess` overridden with `withGeolocation = false`.

### 2. The log-format `%` signs must be doubled (`%%h`)

GoAccess's `--log-format`/`--date-format`/`--time-format` strings are full of
`%` directives (`%h`, `%d`, `%t`, …). Those strings are interpolated into a
**systemd `ExecStart=`**, and in a systemd unit a bare `%` is a *specifier*
(`%h` = the user's home directory, etc.). systemd would silently rewrite your
format before GoAccess ever saw it.

The fix is to double every percent: `%%h`, `%%d`, `%%t`. `%%` is systemd's
literal-percent escape; it collapses back to a single `%` before the argument
reaches GoAccess. **This is not a Nix quirk** — `%` is not special in Nix
strings — it is purely a systemd-unit escaping rule. The default `logFormat`
in this module is already correctly doubled; keep any custom format doubled
too. (Named presets like `COMBINED` contain no `%` and need no escaping.)

## Usage

```nix
{
  imports = [ ./goaccess-live-nginx-dashboard ];

  services.goaccessDashboard = {
    enable = true;
    domain = "stats.example.com";

    # Who may view the dashboard. It leaks full request logs — keep this tight.
    allowedIPs = [ "203.0.113.0/24" "198.51.100.7" ];

    # Reuse an existing ACME cert instead of requesting a fresh one:
    # useACMEHost = "example.com";
  };
}
```

Requires `services.nginx` (the module enables it) and a working ACME/TLS setup
for `domain` — either point `useACMEHost` at an existing certificate or let the
module request its own (configure `security.acme.acceptTerms` / `defaults.email`
yourself).

### Key options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `domain` | — (required) | FQDN the dashboard is served on. |
| `allowedIPs` | loopback + RFC1918 | IPs/CIDRs allowed to view `/` and `/ws`. **Set this.** |
| `useACMEHost` | `null` | Reuse a named ACME cert; `null` = request own cert. |
| `accessLog` | `/var/log/nginx/access.log` | Log GoAccess tails. |
| `logFormat` | combined + vhost | `--log-format`, percent signs **doubled**. |
| `dataDir` | `/var/lib/goaccess` | On-disk DB + rendered HTML. |
| `realTimePort` | `7890` | Loopback port for the WebSocket feed. |
| `htmlTitle` | `Web Server Analytics` | Title rendered at the top of the dashboard. |
| `openFirewall` | `false` | Open `realTimePort`; unnecessary in the normal nginx-proxied setup. |
| `geoipDatabaseDir` | `/var/lib/geoip-databases` | Where the `.mmdb` files live. |
| `geoipDatabases` | `GeoLite2-City.mmdb`, `GeoLite2-ASN.mmdb` | Filenames passed as `--geoip-database`; the first doubles as the `preStart` presence probe. |
| `geoipUpdater.enable` | `false` | Opt-in timer that downloads GeoLite2 DBs from a third-party mirror. |
| `geoipUpdater.interval` | `weekly` | `OnCalendar` refresh cadence for that timer. |
| `geoipUpdater.databases` | City + ASN from the public mirror | `{ name; url; }` pairs the updater fetches. |

`dateFormat`, `timeFormat`, `user`/`group`, `uid`/`gid` round out the set; all
follow the same conventions (percent signs doubled for the format strings).

## GeoIP databases

The geo map needs GeoLite2 `.mmdb` files. Two ways to supply them:

- **Provision them yourself (default / recommended).** With
  `geoipUpdater.enable = false` (the default) you populate `geoipDatabaseDir`
  another way — e.g. nixpkgs' `services.geoipupdate` with a free MaxMind
  license key. The GoAccess service `preStart` hard-fails if the first
  configured database is missing, so you get a clear error instead of an
  empty map.
- **Bundled updater (opt-in).** `geoipUpdater.enable = true` installs a systemd
  timer that downloads the databases into `geoipDatabaseDir`. It pulls from a
  public GitHub mirror that republishes MaxMind's GeoLite2 files **without an
  account or license key**. Trade-off: you trust that mirror's freshness and
  integrity (no checksum verification) — see Security notes. Point
  `geoipUpdater.databases` at MaxMind's own authenticated URLs if you have a
  license key.

The updater's `oneshot` uses `RemainAfterExit`, and the GoAccess service
`Wants`/`After` it, so GoAccess won't start until the databases exist at least
once.

## Notes & caveats

- **`--persist` / `--restore`.** GoAccess's DB is in-memory; these flags
  checkpoint it to `dataDir/db` so history survives restarts. Without them a
  restart drops all history back to the log file's current window.
- **`nginx` group membership.** The GoAccess user joins the `nginx` group (to
  read the access log) and the `nginx` user joins the dashboard's group (to
  serve the generated HTML). Both directions are needed.
- **WebSocket URL.** The service advertises `wss://<domain>/ws`, matching the
  nginx `/ws` proxy location with a long `proxy_read_timeout` so the live socket
  stays open.
- **Firewall.** `realTimePort` is bound to `127.0.0.1` and reverse-proxied by
  nginx, so it does not need to be open. `openFirewall` exists for unusual
  topologies but defaults off.

## Security notes

- **The bundled updater trusts a third-party mirror — that's why it's off by
  default.** With `geoipUpdater.enable = true`, a weekly timer fetches `.mmdb`
  binaries over HTTPS from a public GitHub account that republishes MaxMind's
  GeoLite2 files. There is **no checksum/signature verification**, so enabling
  it means trusting that account indefinitely: if it is compromised or
  hijacked, the replaced database is downloaded automatically on the next run
  and parsed by `libmaxminddb` inside the GoAccess process. Prefer the default
  posture of provisioning the databases yourself (e.g. nixpkgs'
  `services.geoipupdate` with a MaxMind license key), or point
  `geoipUpdater.databases` at MaxMind's own authenticated URLs.
- **The rendered dashboard contains full visitor logs.** The webroot
  (`dataDir/html`) is mode `0750`, owned by the GoAccess group that nginx joins,
  so local accounts outside that group cannot read it off disk. The IP
  allow-list (`allowedIPs`) is the only thing keeping it off the network — keep
  it tight.
