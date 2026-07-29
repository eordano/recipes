# geoip-database-provider

A single, credential-free NixOS provider for the MaxMind GeoLite2 databases
(City, Country, ASN). One host-wide oneshot fetches the `.mmdb` files into a
shared directory; every consumer (log analyzers like GoAccess, firewall
geo-blocking, geoip-aware apps) reads that directory directly and never
downloads its own copy.

## The problem

- **MaxMind gates the official downloads.** Fetching GeoLite2 from MaxMind
  requires an account and a license key. That means a credential to store,
  scope, and rotate on every host that wants a geo database — annoying for a
  fleet and overkill when several services on one host all want the same file.
- **Consumers race the download.** A service that needs the database at
  start-up will find an empty directory if it boots before anything has fetched
  it.

## The approach and its traps

- **P3TERX mirror instead of MaxMind.** The default `mirrorBaseUrl` points at
  the `P3TERX/GeoLite.mmdb` GitHub mirror, which republishes the same GeoLite2
  files under the same license with no auth wall — so there are **no
  credentials to store or rotate**. The trade-off: you trust a third party for
  freshness and integrity, and there is **no checksum verification** of the
  downloaded files. If that trade-off is unacceptable, point `mirrorBaseUrl` at
  your own mirror or a MaxMind-authenticated endpoint.

- **`RemainAfterExit` gates consumers.** The updater is a `oneshot` with
  `RemainAfterExit = true`, so after a successful run the unit stays reported as
  *active*. A consumer service that declares
  `after = [ "geoip-updater.service" ]; wants = [ "geoip-updater.service" ];`
  therefore won't start until the databases have been fetched at least once.
  This is the whole point of the pattern — ordering, not just a cron job.

- **Activation-time initial download.** The systemd timer's `OnBootSec` fires a
  few minutes after boot, but a consumer deployed *alongside* this module in the
  same activation would find an empty directory in the meantime. The
  `system.activationScripts` block does a one-time synchronous fetch when the
  first database file is missing, closing that gap. It ends with `|| true` so a
  failed download never aborts system activation.

- **Jitter avoids a thundering herd.** `RandomizedDelaySec` (default `1h`)
  spreads the scheduled refresh across a fleet so many hosts don't all hit the
  mirror in the same minute.

## Usage

```nix
{
  imports = [ ./modules/geoip-database-provider ];

  modules.services.geoip-databases.enable = true;
}
```

A consumer service gates on the provider like this:

```nix
systemd.services.my-geoip-consumer = {
  after = [ "geoip-updater.service" ];
  wants = [ "geoip-updater.service" ];
  # reads /var/lib/geoip-databases/GeoLite2-City.mmdb etc.
};
```

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the provider on. |
| `dataDir` | `/var/lib/geoip-databases` | Where the `.mmdb` files land; consumers read here. |
| `user` / `group` | `geoip` | System user/group owning the dir and running the updater. |
| `mirrorBaseUrl` | P3TERX GitHub mirror | Base URL each database filename is appended to. |
| `databases` | City, Country, ASN `.mmdb` | Filenames to fetch; the first is the presence probe. |
| `updateInterval` | `weekly` | Refresh cadence (`OnCalendar` format). |
| `randomizedDelaySec` | `1h` | Jitter on the scheduled refresh. |

## Caveats

- No integrity/checksum verification of the downloaded databases with the
  default mirror. Transport is TLS-verified, but the content is trusted on the
  word of a third-party GitHub account; a fixed hash can't be pinned because the
  databases are mutable (refreshed weekly). If that mirror or account were
  compromised, poisoned mappings would land silently — so treat this data as
  advisory, and if you feed it into firewall geo-blocking or other
  security-sensitive decisions, host your own mirror or a MaxMind-authenticated
  endpoint via `mirrorBaseUrl` instead.
- The updater hard-fails (`curl -fL`) on an HTTP error so a bad fetch doesn't
  silently overwrite a good database with an error page. An already-present old
  copy is left in place if a later refresh fails.
- GeoLite2 accuracy and the mirror's update lag are inherited from upstream;
  this module only handles distribution and ordering.
