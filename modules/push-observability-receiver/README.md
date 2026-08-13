# push-observability-receiver

A NixOS module for the **receiver** half of a push-based observability stack.
Remote hosts **push** their journald logs and node metrics to this box over the
Vector protocol; the box fans logs into a **log database** and metrics into a
**metric database**, and serves both through **Grafana** behind nginx.

Which pair of databases that is comes from `backend`: `loki-prometheus` (the
default) or `victoria`.

```
  host A -+  (vector proto :4044 logs)
  host B -+--►  Vector  -► Loki | VictoriaLogs -+
  host C -+  (vector proto :4045 metrics)       |
                    |                            +-► Grafana -► nginx (TLS)
                    +-► Prometheus | VictoriaMetrics remote-write +
                        + local node-exporter scrape
                        + optional extra scrape jobs
```

## The problem it solves

Central log/metric aggregation without letting the central box reach into every
agent. Agents open the connection **outbound** and push; the receiver never
scrapes them. That inverts the usual Prometheus pull model and works cleanly
across NAT, firewalls, and overlay networks -- the receiver only needs two
inbound TCP ports, and a dead agent shows up as *absence of pushes* (which you
can alert on) rather than a scrape you have to configure per host.

## Choosing a backend

`backend = "loki-prometheus"` (default) runs Loki and Prometheus.
`backend = "victoria"` runs VictoriaLogs and VictoriaMetrics in their place.
Nothing above the database moves: the agents keep pushing the same Vector
protocol, and the two Grafana datasources keep the **uids** `loki` and
`prometheus` and the **names** `Loki` and `Prometheus` -- only their `type` and
`url` change. That is deliberate on both counts:

- Stable **uids** mean provisioned dashboards and alert rules carry over with
  no rewrite, and a rule provisioned under one backend isn't orphaned in a live
  Grafana DB after a switch.
- Stable **names** are what make the switch reversible. Grafana's datasource
  provisioner matches by *name*, so renaming `Loki` -> `VictoriaLogs` while
  keeping the uid needs `deleteDatasources` to avoid a uid collision -- and then
  rolling *back* collides in reverse. The cosmetic wart of a VictoriaLogs
  datasource called "Loki" buys a symmetric rollback with zero DB migration.

**PromQL is unaffected.** VictoriaMetrics serves it at `/prometheus`, accepts
Prometheus remote-write on `/api/v1/write` with no extra flag (unlike
Prometheus, which needs `--web.enable-remote-write-receiver`), and the
datasource stays the stock `prometheus` type. Metric dashboards and PromQL
alert rules need no edits whatsoever.

**LogQL is not.** VictoriaLogs has *no* Loki-compatible query API --
`/loki/api/v1/query_range` and `/select/loki/api/v1/*` all answer HTTP 400 -- so
under `victoria` the log datasource is the `victoriametrics-logs-datasource`
plugin speaking LogsQL, and **every log query you supply has to be rewritten**.
Budget for that before flipping the option; it is the whole cost of the switch.

Under `victoria` both databases are relocated onto `dataDir`. The upstream
NixOS modules run them with `DynamicUser = true` and a `StateDirectory`, which
would park the data in `/var/lib/private/<name>` under a uid that is not stable
by contract -- no good for the persistent storage `dataDir` exists to name. So
this module forces `DynamicUser = false`, runs both units as the recipe's own
pinned `user`/`uid`, clears `StateDirectory`, and appends a second
`-storageDataPath` to `extraOptions`. That last flag is not a hack: both
binaries take the **last** value of a repeated flag, which is the only seam the
upstream modules leave (they hardcode `-storageDataPath=/var/lib/${stateDir}`).

## The interesting part: what Grafana can't provision

Grafana file-provisioning covers datasources, dashboards, and alerting -- but a
few things it simply cannot express. This module bolts those on as **oneshot
units ordered off `grafana.service`**, and the non-obvious detail is that
**Grafana creates its database and HTTP surface lazily on first start**. So each
oneshot has to *poll* before it can act:

- **`grafana-secret-key`** -- generates a stable `secret_key` (Grafana ships a
  constant default) *before* Grafana starts, and pins it to a `0400` file.
- **`grafana-home-preference`** -- the org home dashboard can't be set via
  provisioning, so this writes the `preferences` row straight into
  `grafana.db`. It polls for the DB file first, then retries the write under a
  `busy_timeout` because Grafana may still hold the sqlite lock at boot.
- **`grafana-admin-password-reset`** -- resets the admin password from a secret
  file, but **only when the secret's sha256 changes**. A flag file records the
  last-applied hash; without that guard the reset runs on every activation,
  fighting any password you set in the UI and needlessly rewriting the DB.
- **`grafana-playlist`** -- playlists aren't file-provisionable, so it
  POST/PUTs over the HTTP API. It needs the admin password *and* a healthy
  Grafana, so it polls `/api/health`, then probes the playlist by uid to decide
  create-vs-update (the API has no idempotent upsert).

If you take one thing from this recipe, take that pattern: **provision the
un-provisionable via oneshots that poll for Grafana's lazily-created state.**

None of these four oneshots runs as root. `dataDir/grafana` is tmpfiles-owned
`grafana:grafana`, so all four run as `User = "grafana"` -- a file any of them
creates or a DB row any of them writes lands correctly owned without a `chown`
step. Both oneshots that need `adminPasswordFile` -- `grafana-playlist` and
`grafana-admin-password-reset` -- read it through `LoadCredential=` and pick it
up at `$CREDENTIALS_DIRECTORY/admin-pw`, never by `cat`-ing the option path.
PID 1 (still root) does the reading, so the secret file does **not** have to be
readable by the `grafana` user; a `0400 root:root` secret works. All four
oneshots are the same shape as each other; if you add a fifth
un-provisionable oneshot here, match it (and use `LoadCredential=` for
anything secret).

## Other traps baked in

- **Self-referential log spam is dropped twice.** Loki logs a `context
  canceled` line for every cancelled query; because this same box ingests its
  own journal, that would feed back into Loki forever. It's filtered once in
  the Vector pipeline (`drop_loki_query_cancel_noise`) and once in the Loki
  unit's `LogFilterPatterns` -- belt and suspenders, at two different layers.
  Both exist only under `loki-prometheus`; VictoriaLogs doesn't produce that
  chatter, and declaring `systemd.services.loki` while `services.loki.enable`
  is false would emit a malformed unit.
- **The VictoriaLogs sink needs `path`, not a query string on `endpoint`.**
  VictoriaLogs accepts the Loki push protocol, but only at
  `/insert/loki/api/v1/push`, and the `json` codec means the message text
  arrives in a field called `message` -- without `?_msg_field=message` every
  record's `_msg` is VictoriaLogs' "missing _msg field" placeholder. Vector's
  loki sink **silently drops a query string written into `endpoint`**: config
  validation passes, then every batch comes back HTTP 400 forever. The query
  string only takes effect on `path`.
- **The loki sink's healthcheck ignores `path`.** It probes `endpoint +
  /ready`, which VictoriaLogs answers with a 400, so `healthcheck.enabled =
  false` is mandatory on that sink or Vector logs a healthcheck failure at
  every start.
- **GeoIP skips internal addresses.** Enrichment only fires for real external
  IPs; private, CGNAT and loopback addresses are short-circuited before the
  lookup, so internal traffic doesn't waste lookups or mislabel. The test is
  real CIDR containment (`ip_cidr_contains`), covering exactly
  `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` (RFC 1918),
  `100.64.0.0/10` (RFC 6598 shared address space, which is also where
  Tailscale-style overlays live), `127.0.0.0/8` and `::1/128` (loopback),
  `169.254.0.0/16` and `fe80::/10` (link-local), and `fc00::/7` (IPv6 ULA).
  Do **not** be tempted back into `starts_with` prefixes: `"172.2"` matches
  public space such as `172.2.0.0/16` and `172.217.0.0/16`, and `"100.64."`
  is only a /16 of the /10. Add ranges here if your address plan needs it.
- **Prometheus tolerates out-of-order samples** (`out_of_order_time_window`)
  because pushed metrics from many agents don't arrive in strict timestamp
  order. VictoriaMetrics needs no equivalent knob.
- **`job = "node"` is load-bearing.** Both backends scrape the local node
  exporter under exactly that job name with a `host` label, because dashboards
  and alert rules filter on it. The self-scrape job is not: under
  `loki-prometheus` it's `prometheus`, under `victoria` it's two jobs,
  `victoriametrics` and `victorialogs`.
- **Container severity is sniffed from the message body**, since `podman-*` /
  `docker.service` units don't set journald `PRIORITY` -- the pipeline scans for
  `[ERROR]`, `- WARN -`, tracebacks, etc. so dashboards can filter by severity.
- **`StateDirectory` is forced off** for Grafana so its state lives in your
  persistent `dataDir`, not an ephemeral `/var/lib` StateDirectory.

## Usage

```nix
{
  imports = [ ./push-observability-receiver ];

  services.push-observability-receiver = {
    enable = true;
    domain = "logs.example.com";
    acmeHost = "logs.example.com";           # null -> plain HTTP (TLS upstream)
    dataDir = "/var/lib/push-observability"; # put on persistent storage

    # "loki-prometheus" (default) or "victoria" (VictoriaLogs +
    # VictoriaMetrics). Switching to "victoria" means rewriting every log
    # query from LogQL to LogsQL -- see "Choosing a backend" above.
    # backend = "victoria";

    # Optional: sync the admin password from a secret file (agenix / sops /
    # a tmpfiles rule -- anything readable by the grafana user).
    adminPasswordFile = "/run/secrets/grafana-admin-password";

    # Optional: file-provision your own dashboards, and pin one as home.
    dashboardsDir = ./dashboards;   # a dir of *.json; home.json -> default home
    homeDashboardUid = "home";

    # Optional: rotate dashboards on a wall display (needs adminPasswordFile).
    playlist.items = [
      { uid = "home";   title = "Overview"; }
      { uid = "triage"; title = "Triage -- USE"; }
    ];

    # Optional: your own Grafana alerting provisioning (contact points,
    # policies, rule groups). Passed straight through -- alert rules name your
    # own hosts/services, so they're yours to write.
    # alerting = { apiVersion = 1; ... };
  };
}
```

### Agent side (each host that pushes)

Agents run their own Vector with the journald source and a `vector` sink
pointing at this receiver, e.g.:

```toml
[sinks.central_logs]
type = "vector"
inputs = ["journald"]
address = "logs.example.com:4044"

[sinks.central_metrics]
type = "vector"
inputs = ["host_metrics"]
address = "logs.example.com:4045"
```

Put those two ports behind your VPN/overlay or an mTLS proxy -- the vector
protocol is not authenticated. By default the module **binds both ingest ports
to `127.0.0.1` and does NOT open the firewall**, so out of the box nothing is
reachable off-box. Point `listenAddress` at the private/overlay interface your
agents use, and only set `openFirewall = true` once the ports are on a trusted
network or behind an authenticated tunnel.

## Key options

| Option | Default | Purpose |
|---|---|---|
| `domain` | -- (required) | nginx vhost / Grafana server domain |
| `backend` | `"loki-prometheus"` | database pair: Loki + Prometheus, or `"victoria"` |
| `acmeHost` | `null` | ACME cert host; null = plain HTTP |
| `enableNginx` | `true` | front Grafana with nginx (opens 80/443) |
| `vectorPort` / `metricsPort` | `4044` / `4045` | pushed logs / metrics |
| `listenAddress` | `127.0.0.1` | interface the (unauthenticated) ingest ports bind to |
| `openFirewall` | `false` | open the firewall for the ingest ports (opt-in) |
| `lokiPort` / `grafanaPort` / `prometheusPort` | `3100` / `3000` / `9090` | loopback service ports (`loki-prometheus`) |
| `victoriaLogsPort` / `victoriaMetricsPort` | `9428` / `8428` | loopback service ports (`victoria`) |
| `nodeExporterPort` | `9100` | local node exporter the metric database scrapes |
| `dataDir` | `/var/lib/push-observability` | log + metric database and Grafana state |
| `user` | `"push-observability"` | system user owning `dataDir` |
| `uid` / `gid` | `3100` / `3100` | pinned so persisted data keeps its owner |
| `retentionPeriod` / `metricsRetentionPeriod` | `168h` / `30d` | log / metric retention |
| `logLevel` | `"info"` | log level for the databases and Grafana (`debug`...`error`) |
| `adminPasswordFile` | `null` | secret file for the admin-password sync oneshot |
| `dashboardsDir` | `null` | dir of dashboard JSON to file-provision |
| `homeDashboardUid` | `null` | dashboard uid pinned as org home |
| `playlist.items` | `[]` | dashboards to rotate (needs `adminPasswordFile`) |
| `playlist.uid` / `.name` / `.interval` | `"rotation"` / `"Rotation"` / `"30s"` | identity + dwell time of that playlist |
| `alerting` | `null` | passthrough for `services.grafana.provision.alerting` |
| `enableGeoIP` | `false` | enrich external IPs (needs `geoipDatabaseDir`) |
| `geoipDatabaseDir` | `/var/lib/GeoIP` | where `GeoLite2-{City,ASN}.mmdb` live |
| `geoipUpdaterUnit` | `null` | unit to order Vector after (mmdb refresh) |
| `udmSyslog.*` | disabled | UDP syslog ingest + firewall-log parsing |
| `extraScrapeJobs` | `[]` | raw Prometheus `scrape_configs` for pull-only sources |
| `smtp.*` | disabled | Grafana email notifications |

## Caveats

- **The vector protocol ports are unauthenticated.** They default to binding
  `127.0.0.1` with the firewall closed. Set `listenAddress` to a trusted
  private/overlay interface for your agents, and flip `openFirewall = true`
  only when the ports are on a trusted network or behind an authenticated
  tunnel/mTLS proxy. The module never adds auth itself.
- **GeoLite2 databases are not downloaded for you.** Point `geoipDatabaseDir`
  at a directory you keep fresh (e.g. `geoipupdate` on a timer) and optionally
  set `geoipUpdaterUnit` so Vector starts after it.
- **Dashboards and alert rules are yours to supply.** This recipe is the plumbing
  (ingest, storage, provisioning mechanics, the Grafana-can't-express-it
  oneshots), not a dashboard pack. `dashboardsDir` file-provisions whatever JSON
  you drop in; `alerting` passes your rule groups straight through.
- **Single-binary, filesystem-backed Loki** with `replication_factor = 1`. Fine
  for a homelab or a small fleet; not an HA/object-store deployment. The
  `victoria` backend is likewise single-node.
- **Switching `backend` does not migrate data.** The new pair of databases
  starts empty and the old data is left on disk under `dataDir` for you to
  delete by hand once the switch has proven out; nothing here removes it. Plan
  for a history gap the length of your retention window at cutover.
- **`backend = "victoria"` installs a Grafana plugin.**
  `victoriametrics-logs-datasource` is added via `declarativePlugins`, which
  also flips Grafana's plugin path to a read-only store `linkFarm` and disables
  the background plugin installer. If your Grafana can't reach `grafana.com`,
  check `/api/datasources/uid/loki/health` after the first start: a signature
  rejection shows up there, not in `/api/health`.
- **`udmSyslog` binds a UDP port** and, unlike the vector ingest ports, opens it
  in the firewall unconditionally whenever `udmSyslog.enable` is set (there is
  no `openFirewall` gate for it). Keep `udmSyslog.bindAddress` on a private/LAN
  interface so it isn't reachable from the internet.
