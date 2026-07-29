# push-observability-receiver

A NixOS module for the **receiver** half of a push-based observability stack.
Remote hosts **push** their journald logs and node metrics to this box over the
Vector protocol; the box fans logs into **Loki** and metrics into
**Prometheus**, and serves both through **Grafana** behind nginx.

```
  host A ─┐  (vector proto :4044 logs)
  host B ─┼──►  Vector  ─► Loki ─────┐
  host C ─┘  (vector proto :4045 metrics)  │
                    │                       ├─► Grafana ─► nginx (TLS)
                    └─► Prometheus remote-write ┘
                        + local node-exporter scrape
                        + optional extra scrape jobs
```

## The problem it solves

Central log/metric aggregation without letting the central box reach into every
agent. Agents open the connection **outbound** and push; the receiver never
scrapes them. That inverts the usual Prometheus pull model and works cleanly
across NAT, firewalls, and overlay networks — the receiver only needs two
inbound TCP ports, and a dead agent shows up as *absence of pushes* (which you
can alert on) rather than a scrape you have to configure per host.

## The interesting part: what Grafana can't provision

Grafana file-provisioning covers datasources, dashboards, and alerting — but a
few things it simply cannot express. This module bolts those on as **oneshot
units ordered off `grafana.service`**, and the non-obvious detail is that
**Grafana creates its database and HTTP surface lazily on first start**. So each
oneshot has to *poll* before it can act:

- **`grafana-secret-key`** — generates a stable `secret_key` (Grafana ships a
  constant default) *before* Grafana starts, and pins it to a `0400` file.
- **`grafana-home-preference`** — the org home dashboard can't be set via
  provisioning, so this writes the `preferences` row straight into
  `grafana.db`. It polls for the DB file first, then retries the write under a
  `busy_timeout` because Grafana may still hold the sqlite lock at boot.
- **`grafana-admin-password-reset`** — resets the admin password from a secret
  file, but **only when the secret's sha256 changes**. A flag file records the
  last-applied hash; without that guard the reset runs on every activation,
  fighting any password you set in the UI and needlessly rewriting the DB.
- **`grafana-playlist`** — playlists aren't file-provisionable, so it
  POST/PUTs over the HTTP API. It needs the admin password *and* a healthy
  Grafana, so it polls `/api/health`, then probes the playlist by uid to decide
  create-vs-update (the API has no idempotent upsert).

If you take one thing from this recipe, take that pattern: **provision the
un-provisionable via oneshots that poll for Grafana's lazily-created state.**

None of these four oneshots runs as root. `dataDir/grafana` is tmpfiles-owned
`grafana:grafana`, so all four run as `User = "grafana"` — a file any of them
creates or a DB row any of them writes lands correctly owned without a `chown`
step. Both oneshots that need `adminPasswordFile` — `grafana-playlist` and
`grafana-admin-password-reset` — read it through `LoadCredential=` and pick it
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
  unit's `LogFilterPatterns` — belt and suspenders, at two different layers.
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
  order.
- **Container severity is sniffed from the message body**, since `podman-*` /
  `docker.service` units don't set journald `PRIORITY` — the pipeline scans for
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
    acmeHost = "logs.example.com";           # null → plain HTTP (TLS upstream)
    dataDir = "/var/lib/push-observability"; # put on persistent storage

    # Optional: sync the admin password from a secret file (agenix / sops /
    # a tmpfiles rule — anything readable by the grafana user).
    adminPasswordFile = "/run/secrets/grafana-admin-password";

    # Optional: file-provision your own dashboards, and pin one as home.
    dashboardsDir = ./dashboards;   # a dir of *.json; home.json → default home
    homeDashboardUid = "home";

    # Optional: rotate dashboards on a wall display (needs adminPasswordFile).
    playlist.items = [
      { uid = "home";   title = "Overview"; }
      { uid = "triage"; title = "Triage — USE"; }
    ];

    # Optional: your own Grafana alerting provisioning (contact points,
    # policies, rule groups). Passed straight through — alert rules name your
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

Put those two ports behind your VPN/overlay or an mTLS proxy — the vector
protocol is not authenticated. By default the module **binds both ingest ports
to `127.0.0.1` and does NOT open the firewall**, so out of the box nothing is
reachable off-box. Point `listenAddress` at the private/overlay interface your
agents use, and only set `openFirewall = true` once the ports are on a trusted
network or behind an authenticated tunnel.

## Key options

| Option | Default | Purpose |
|---|---|---|
| `domain` | — (required) | nginx vhost / Grafana server domain |
| `acmeHost` | `null` | ACME cert host; null = plain HTTP |
| `enableNginx` | `true` | front Grafana with nginx (opens 80/443) |
| `vectorPort` / `metricsPort` | `4044` / `4045` | pushed logs / metrics |
| `listenAddress` | `127.0.0.1` | interface the (unauthenticated) ingest ports bind to |
| `openFirewall` | `false` | open the firewall for the ingest ports (opt-in) |
| `lokiPort` / `grafanaPort` / `prometheusPort` | `3100` / `3000` / `9090` | loopback service ports |
| `nodeExporterPort` | `9100` | local node exporter Prometheus scrapes |
| `dataDir` | `/var/lib/push-observability` | Loki + Prometheus + Grafana state |
| `user` | `"push-observability"` | system user owning `dataDir` |
| `uid` / `gid` | `3100` / `3100` | pinned so persisted data keeps its owner |
| `retentionPeriod` / `metricsRetentionPeriod` | `168h` / `30d` | Loki / Prometheus retention |
| `logLevel` | `"info"` | log level for Loki and Grafana (`debug`…`error`) |
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
  for a homelab or a small fleet; not an HA/object-store deployment.
- **`udmSyslog` binds a UDP port** and, unlike the vector ingest ports, opens it
  in the firewall unconditionally whenever `udmSyslog.enable` is set (there is
  no `openFirewall` gate for it). Keep `udmSyslog.bindAddress` on a private/LAN
  interface so it isn't reachable from the internet.
