# blackbox-endpoint-probes

A NixOS module that bundles the [blackbox exporter](https://github.com/prometheus/blackbox_exporter)
with the Prometheus scrape job that drives it, so **one `targets` list** configures
both. Each target becomes an external "is this endpoint actually answering?" probe
emitting `probe_success{service=<name>}` (0/1) and `probe_duration_seconds{service=<name>}`.

## The problem

Blackbox probing on Prometheus is deceptively fiddly. You have to:

1. Run the exporter with a set of probe *modules* (`http_2xx`, `tcp_connect`, …).
2. Write a scrape job that does **not** scrape your target URLs directly, but
   instead scrapes the *exporter's* `/probe` endpoint with the target passed as a
   query param.

That second step needs a specific relabel dance, and the default HTTP module has a
success/failure definition that surprises people. This module encodes both so a
target list is all you write.

## Two traps this solves

### 1. `http_2xx` treats 4xx as success

The upstream-flavored `http_2xx` module used here lists 4xx codes
(`400 401 403 404`) in `valid_status_codes`. So a probe against a URL that returns
**404 still reports `probe_success=1`**. It only fails on connection refused, TLS
errors, or timeout — it's a "the server is up and routing" check, not a
"this endpoint works" check.

If you want a 404 (or any non-2xx) to page, put the target on the
**`http_strict_2xx`** module, whose `valid_status_codes = [ ]` means "real 2xx
only". Choosing the wrong module here is the difference between a monitor that
catches an outage and one that silently passes while your app 500s.

All modules pin `preferred_ip_protocol = "ip4"` so a probe result doesn't quietly
depend on the host's IPv6 reachability.

### 2. The `__address__` → `__param_target` relabel indirection

To scrape blackbox you must rewrite the scrape target. The relabel chain:

1. copy the target (`__address__`) into `__param_target`,
2. copy the module meta-label into `__param_module`,
3. keep the original URL as the `instance` label (so it reads sensibly in graphs),
4. **rewrite `__address__` to the exporter itself**, turning the actual request
   into `http://<exporter>/probe?target=<url>&module=<module>`.

Skip step 4 and Prometheus tries to scrape your target URLs directly (as if they
were `/metrics` endpoints) and everything fails. This is the single most common
blackbox misconfiguration.

A trailing per-target relabel maps each probed URL back to its short `service`
label. The URL is `lib.escapeRegex`'d, so a target containing regex metacharacters
(`?`, `+`, `.`) can't accidentally match and mislabel a different target.

## Usage

Import the module and enable it with a targets list:

```nix
{
  imports = [ ./modules/blackbox-endpoint-probes ];

  services.blackboxEndpointProbes = {
    enable = true;
    targets = [
      # "up and routing" check — 404 still counts as success
      { service = "site"; url = "https://example.com/"; }

      # strict check — non-2xx fails the probe
      {
        service = "api";
        url = "https://example.com/health";
        module = "http_strict_2xx";
      }

      # raw TCP reachability
      {
        service = "db";
        url = "your-host:5432";
        module = "tcp_connect";
      }

      # ping
      { service = "gateway"; url = "your-host"; module = "icmp"; }
    ];
  };
}
```

### Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn on the exporter + scrape job. |
| `targets` | `[ ]` | List of `{ service; url; module ? "http_2xx"; }`. |
| `port` | `9115` | Exporter listen port. |
| `listenAddress` | `"127.0.0.1"` | Exporter bind address (loopback keeps the probe surface off the network). |
| `probeInterval` | `"30s"` | How often each probe runs. |
| `probeTimeout` | `"10s"` | Per-scrape timeout; keep `>=` the module `timeout`. |
| `modules` | four built-ins | Blackbox module config; override to add custom probers. |

The `module` field on each target is an enum over the built-in modules
(`http_2xx`, `http_strict_2xx`, `tcp_connect`, `icmp`). To add your own prober,
override `modules` and reference it — note the enum in `targets` would need
widening if you want the type checker to accept a new module name.

## Caveats

- **Requires an existing Prometheus.** This module appends to
  `services.prometheus.scrapeConfigs`; it does not enable Prometheus itself.
- The exporter binds to loopback by default. If Prometheus runs on another host,
  point `listenAddress` at a reachable interface (and firewall the port).
- `icmp` probing needs the exporter to have the capability to send raw ICMP; the
  NixOS `services.prometheus.exporters.blackbox` module handles this, but on
  locked-down kernels verify ping probes actually succeed.
- `probeTimeout` is the scrape timeout, distinct from the per-module `timeout` in
  the blackbox config. If the module timeout is longer than the scrape timeout,
  Prometheus gives up first and you get a misleading failure.
