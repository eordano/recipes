# vector-log-metrics-forward

Centralized log + metric shipping with [Vector](https://vector.dev), where the
local `journald` is only a **short-retention buffer** and the durable copy lives
on one or more upstream collectors. A single NixOS module.

## The problem

You have a fleet of boxes and you want their logs (and, optionally, Prometheus
metrics) in one place. You don't want to depend on local disk to keep history,
and you don't want a single collector outage — or the slow bring-up of a VPN
link — to lose events.

This module:

- Runs a Vector pipeline that reads `journald` (+ nginx logs, + an optional
  inbound socket from other nodes) and forwards it to your collector(s).
- Trims `journald` down to a small buffer, because the authoritative copy is
  upstream.
- Fans out to **multiple upstreams in parallel**, each behind its own disk
  buffer, so whichever sink is reachable first carries the data and a wedged
  sink can't stall the others.

## The key insight / traps

These are the parts the config can't explain on its own — the reason this recipe
exists.

### 1. `journald` is a buffer, not the archive

`journaldMaxUse` / `journaldMaxRetentionSec` are deliberately small. The durable
copy is upstream, so local journald only needs to hold enough to survive a short
upstream outage. Keeping it small also stops a wedged upstream + full disk buffer
from being compounded by an unbounded local journal.

### 2. Parse nginx access logs **non-aborting** (`parse_regex`, not `parse_regex!`)

This is the sharpest trap. TLS probers that connect to a plaintext `:80` cause
nginx to log the raw ClientHello bytes as the "request". Those bytes contain a
literal `"`, which terminates the `[^"]+` capture early and **fails the regex**.

With the aborting form (`parse_regex!`), every such line becomes a Vector
`ERROR` and is **dropped** — so you silently lose exactly the traffic you most
want to see. The non-aborting form returns an error value you can branch on:
on failure, forward the raw line tagged `nginx_access_raw` instead of dropping
it.

```vrl
parsed, err = parse_regex(.message, r'...')
if err == null {
  . |= parsed
  .labels.source = "nginx_access"
} else {
  .labels.source = "nginx_access_raw"   # forward raw, don't drop
}
```

### 3. Fan out to a list of upstreams in parallel

`upstream` accepts a list. Each entry gets its own Vector sink and its own
buffer, and events go to **all of them at once**. The motivating case: during a
box's bring-up, a LAN relay is reachable immediately while a VPN/tailnet
collector only becomes reachable a little later. Sending to both means the first
one to answer carries the data, and the buffer holds the rest for the slower
sink — no ordering assumption, no lost events.

### 4. Order Vector after the GeoIP updater

GeoIP enrichment reads `.mmdb` files that a separate updater provisions. If
Vector starts against a missing or half-written database it errors on every
lookup. Set `geoipUpdaterService` and the module adds an `after`/`wants`
ordering so that can't happen.

### 5. Drop known noise once, up front

`dropUnitNoise` filters high-volume, zero-value journald lines (matched by
`_SYSTEMD_UNIT` + a substring) **before** they fan out to every downstream
transform, so you filter each spam line once rather than in every consumer.

## Usage

Import the module and enable it on a shipper:

```nix
{
  imports = [ ./vector-log-metrics-forward ];

  behaviors.logs = {
    useVector = true;

    # One string, or a list to fan out in parallel.
    upstream = [ "relay.lan" "collector.example.com" ];

    enableMetrics   = true;
    enableNginxLogs = true;
    enableGeoIP     = true;
    geoipUpdaterService = "geoip-updater.service"; # your updater unit

    # Optional extra metric sources:
    enableGPUMetrics = true;
    postgresqlExporter = { enable = true; port = 9187; };

    dropUnitNoise = [
      { unit = "some-chatty.service"; contains = "context canceled"; }
    ];
  };
}
```

On the **collector** host, turn on the receiver:

```nix
{
  imports = [ ./vector-log-metrics-forward ];

  behaviors.logs = {
    useVector = true;
    enableLogReceiver = true;
    receiverInterface = "vpn0";     # restrict the open ports to a trusted iface

    # `enableLogReceiver` is a RELAY: received events flow through the same
    # `add_labels` pipeline into the forwarding sinks, i.e. on to `upstream`.
    # So `upstream` must point at the NEXT hop, never back at this host — a
    # self-referencing upstream is an infinite loop. On a terminal collector,
    # point `upstream` at your store's Vector, or add your own sink (see below).
    upstream = "store.internal";
  };
}
```

`enableLogReceiver` opens an inbound Vector source on `logsPort` and merges it
into `add_labels`, so received logs are re-labeled and forwarded like local ones.
To make this host the **terminal** store instead of a relay, extend
`services.vector.settings.sinks` with your own sink reading from `add_labels`
(Loki, Elasticsearch, an object store, …) and point `upstream` at a next hop you
actually want (or a throwaway you don't mind — the fan-out sinks are always
created).

Two receiver caveats:

- **Metrics are not received here.** `enableMetrics` on a receiver only scrapes
  *this* host's local exporters. Forwarded metrics arrive on `metricsPort`, but
  this module binds no inbound source there — add a second `type = "vector"`
  source on `metricsPort` yourself if you want to aggregate remote metrics.
- The firewall opens `metricsPort` whenever `enableMetrics` is set on a receiver,
  even though nothing listens on it yet; harmless, but don't expect it to work
  until you add that source.

### Options

| Option | Default | Purpose |
| --- | --- | --- |
| `useVector` | `false` | Master switch. |
| `upstream` | `""` | Collector host, or list of hosts to fan out to. |
| `logsPort` / `metricsPort` | `4044` / `4045` | Receiver ports. |
| `compression` | `true` | Compress the forwarded stream. |
| `enableMetrics` | `false` | Scrape local exporters and forward metrics. |
| `scrapeIntervalSecs` | `60` | Scrape cadence (raise to cut metric volume). |
| `enableNginxLogs` | `false` | Forward nginx access + error logs. |
| `enableFail2banLogs` | `false` | Forward fail2ban logs. |
| `enableLogReceiver` | `false` | Act as a collector (open inbound socket). |
| `receiverInterface` | `null` | Restrict receiver ports to one interface. |
| `enableGeoIP` | `false` | Enrich nginx logs with GeoIP/ASN. |
| `geoipDatabasePath` | `/var/lib/geoip-databases` | Where the `.mmdb` files live. |
| `geoipUpdaterService` | `null` | Updater unit to order Vector after. |
| `enableGPUMetrics` | `false` | Scrape NVIDIA GPU exporter (`:9835`). |
| `postgresqlExporter` | `{enable=false; port=9187;}` | Scrape a postgres exporter. |
| `upsName` | `"ups"` | NUT UPS name (with `services.prometheus.exporters.nut`). |
| `dropUnitNoise` | `[]` | Unit+substring noise-drop rules. |
| `journaldMaxUse` | `"500M"` | Local journald size cap. |
| `journaldMaxRetentionSec` | `86400` | Local journald time cap. |
| `vectorBufferType` | `"disk"` | `disk` (survives restarts) or `memory`. |
| `vectorBufferMaxSize` | `1073741824` | Disk buffer cap, bytes. |

## Caveats

- **Provide the GeoIP databases yourself.** This module reads
  `GeoLite2-City.mmdb` and `GeoLite2-ASN.mmdb` from `geoipDatabasePath`; it does
  not download or license them. Point `geoipUpdaterService` at whatever refreshes
  them.
- **The metric exporters must exist.** `enableMetrics` scrapes
  `services.prometheus.exporters.node` (enabled by this module), and optionally a
  postgres exporter, an NVIDIA GPU exporter, and `services.prometheus.exporters.nut`
  — enable those separately where you want them.
- **Don't expose the receiver on an untrusted network.** With no
  `receiverInterface` the ports open on all interfaces. Set it to a VPN/private
  interface, or firewall the ports yourself.
- Requires `services.nginx` for the nginx sources and `services.fail2ban` for the
  fail2ban filter; both are guarded, so leaving them off just omits those inputs.
- **It retargets Docker's log driver.** On a host with `virtualisation.docker`
  enabled the module sets `logDriver = "journald"`, so container logs land in
  the journal and get shipped with everything else. If you deliberately run a
  different driver, override it after importing.
- Vector runs with `journaldAccess = true` and `CAP_DAC_READ_SEARCH`, and gets
  read-only access to `/var/log/nginx` (plus the `nginx` supplementary group)
  and to `geoipDatabasePath` only when those features are on.
