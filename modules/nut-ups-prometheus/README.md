# nut-ups-prometheus

A drop-in NixOS module that wires a **locally-attached UPS** into
[NUT](https://networkupstools.org/) (Network UPS Tools) and the Prometheus
**NUT exporter**, with everything bound to `127.0.0.1`. It captures two traps
that bite people the first time they do this, and turns them into options.

## What problem it solves

You have a UPS plugged into a machine over USB and you want:

- NUT to talk to it (`upsc ups@localhost` returns live telemetry), and
- Prometheus to scrape battery charge / runtime, input & output voltage,
  load, temperature, `ups.status`, etc.

The exporter and the NUT server both listen only on loopback, so nothing is
exposed on the network. Remote scraping goes over a VPN or a reverse proxy of
your choosing — the module makes no assumptions about that.

## The two traps (why this exists)

### 1. `nutdrv_qx` misidentifies the device under `port = "auto"`

`usbhid-ups` (the default) autodetects most APC Back-UPS / Smart-UPS USB
models fine. But cheap and OEM "megatec"-protocol units driven by `nutdrv_qx`
are frequently **misidentified** when the port is left on `auto` — the driver
grabs the wrong USB device or fails to match at all.

The fix is an explicit USB match. Run `lsusb`, find the `xxxx:yyyy` for the
UPS, and set:

```nix
services.nut-ups-prometheus = {
  driver    = "nutdrv_qx";
  vendorid  = "0001";   # the part before the colon in lsusb
  productid = "0000";   # the part after
};
```

### 2. Auto-shutdown, deliberately disabled

By default NUT will **power the host down** when the battery reaches critical.
That is often *not* what you want: for machines that should ride the battery
all the way out, an automated shutdown is worse than the outage.

This module defaults to `disableAutoShutdown = true`, which sets
`MINSUPPLIES = 0` and replaces `SHUTDOWNCMD` with a command that only writes a
log line. A critical-battery event is recorded but never triggers a shutdown.

Set `disableAutoShutdown = false` to get the normal, shut-the-host-down
behaviour.

## Usage

```nix
{
  imports = [ ./modules/nut-ups-prometheus ];

  services.nut-ups-prometheus = {
    enable = true;

    # A file containing the NUT monitor-user password. Provide it via any
    # secrets mechanism (plain file, sops-nix, agenix, …). Must be readable
    # by the NUT daemons.
    passwordFile = "/run/secrets/nut-ups-password";

    # APC USB models usually just work with the defaults:
    #   driver = "usbhid-ups";  port = "auto";
    #
    # For an OEM/megatec unit, pin the driver + USB ids instead:
    # driver    = "nutdrv_qx";
    # vendorid  = "0001";
    # productid = "0000";
  };
}
```

Then confirm with `upsc ups@localhost` and scrape
`http://127.0.0.1:9199/ups_metrics` from Prometheus.

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `passwordFile` | *(required)* | Path to the file holding the monitor user's password. |
| `upsName` | `"ups"` | NUT instance name; addressed as `<name>@localhost`. |
| `driver` | `"usbhid-ups"` | NUT driver. Use `nutdrv_qx` for OEM/megatec units. |
| `port` | `"auto"` | Driver port. `auto` = USB autodetect. |
| `vendorid` / `productid` | `null` | Explicit USB match — required when `auto` misidentifies the device. |
| `monUser` | `"monuser"` | Name of the upsmon monitor user. |
| `disableAutoShutdown` | `true` | Ride the battery out instead of shutting down on critical battery. |
| `description` | `"Local UPS"` | Free-text description in `ups.conf`. |
| `extraConfig` | `""` | Lines appended verbatim to the UPS's `ups.conf` section. |
| `exporterPort` | `9199` | prometheus-nut-exporter port (bound to `127.0.0.1`). |

## Caveats

- **Localhost only.** The exporter is bound to `127.0.0.1` explicitly. `upsd`
  gets no `LISTEN` directive from this module, which leaves it on NUT's own
  default of loopback — if you add `power.ups.upsd.listen` entries yourself you
  are widening that. Remote Prometheus scraping must go over a VPN or reverse
  proxy you set up yourself.
- **`passwordFile` permissions.** The file must be readable by the NUT
  service accounts. Mode `0440` with owner/group matching the NUT services is
  a safe default.
- **`extraConfig` is an escape hatch.** Driver settings not covered by the
  named options (polling intervals, battery voltage overrides, …) go there and
  are appended verbatim to the UPS's `ups.conf` section.
