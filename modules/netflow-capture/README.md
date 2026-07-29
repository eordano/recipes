# netflow-capture

A reusable NixOS module that turns `nfdump`'s `nfpcapd` into a declarative,
per-interface NetFlow/IPFIX capture service. You describe a set of named
listeners; the module renders one hardened `nfpcapd-<name>` systemd unit per
interface, auto-creates the on-disk storage layout, and manages the
capture-output user.

## What problem it solves

`nfpcapd` records live traffic off a NIC and writes rotating NetFlow/IPFIX flow
files (and, optionally, raw pcap) that you can later query with `nfdump`. Wiring
it up by hand means: one long argv per interface, a system user for the output,
pre-created directories (it will not make them for you), and a systemd unit that
opens a raw socket but doesn't leave itself running as root longer than needed.

This module collapses all of that into an option tree. Add a listener attribute
and you get a fully-formed, restart-on-failure capture service.

## The traps it encodes

Two things about `nfpcapd` are easy to get wrong, and the module bakes in the
right answer:

1. **It runs as `User=root`, on purpose, even though it's handed `-u/-g`.**
   Opening a raw AF_PACKET capture socket needs root. `nfpcapd` opens the socket
   first, then drops privilege to the configured user itself. If you "fix" the
   unit to run directly as the unprivileged user, the socket open fails with
   `EPERM`. The system user only ever owns the on-disk output — never the running
   process at startup.

2. **`nfpcapd` will not create missing output directories.** If the `-w` path
   (or the raw-pcap `-p` path) doesn't exist, the daemon exits immediately. The
   module therefore emits `systemd.tmpfiles` rules to pre-create the base storage
   dir, each listener's per-interface subdirectory, and any pcap sidecar dir,
   owned by the capture user.

Everything else — worker threads, socket buffer, node cache, snap length, active
and inactive flow-expiration windows, and the file-rotation window — is a
per-listener option so you can tune each interface independently.

## Usage

Import `default.nix` as a NixOS module, then:

```nix
{
  services.nfpcapd = {
    enable = true;

    # Where flow files land. One subdirectory per listener is created underneath.
    storageDir = "/var/log/netflow";

    listeners = {
      # Attribute name is the listener name AND the default interface + subdir name.
      eth0 = {
        enable = true;
        subdirectory = "wired";
      };

      wlo1 = {
        enable = true;
        workerThreads = 4;      # bump when compression is enabled at high levels
        socketBufferMB = 64;    # raise on high-throughput links to avoid drops
        rotateTime = 60;        # rotate flow files every 60s
      };

      # Capture only DNS, and also keep raw pcap on the side.
      dns = {
        enable = true;
        interface = "eth0";
        subdirectory = "dns";
        capturePcapDirectory = "/var/log/nfpcapd/pcap";
        additionalOptions = "'port 53 and proto udp'";
      };
    };
  };
}
```

Query the captured flows afterwards with `nfdump -R /var/log/netflow/wired`.

## Options

Top-level (`services.nfpcapd`):

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Master switch. Asserts at least one listener is configured. |
| `storageDir` | `/var/log/netflow` | Base output dir; one subdir per listener underneath. |
| `user` / `group` | `nfpcapd` | System user/group that owns the capture output. |
| `listeners` | `{}` | Attrset of named listeners (see below). |
| `globalAdditionalOptions` | `""` | Extra argv appended to every listener. |

Per listener (`services.nfpcapd.listeners.<name>`):

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Enable this listener's unit. |
| `interface` | listener name | NIC to capture from (`-i`). |
| `subdirectory` | listener name | Output subdir under `storageDir`. |
| `capturePcapDirectory` | `null` | If set, also write raw pcap here (`-p`). |
| `workerThreads` | `2` | Worker threads (`-W`). Keep ≤ logical core count. |
| `socketBufferMB` | `20` | Capture socket buffer in MB (`-b`). |
| `nodeCacheSize` | `524288` | Flow node cache size in bytes (`-B`). |
| `snaplen` | `1522` | Snapshot length (`-s`). |
| `activeExpirationSeconds` | `300` | Active flow expiry (`-e` first field). |
| `inactiveExpirationSeconds` | `60` | Inactive flow expiry (`-e` second field). |
| `rotateTime` | `300` | File rotation window, seconds or an nfdump time expr (`-t`). |
| `verboseMode` | `false` | Echo captured data to stdout (`-E`); debugging only. |
| `additionalOptions` | `""` | Extra argv for this listener (BPF filter, compression, etc.). |

## Caveats

- Requires the `nfdump` package (pulled from `pkgs` at build time).
- The service opens raw capture sockets — it needs to run on the host with the
  NIC, not inside a network namespace that can't see the traffic.
- High packet rates want a larger `socketBufferMB` (and possibly `nodeCacheSize`)
  to avoid kernel-side drops; short `rotateTime` values create many small files.
- `RestartPreventExitStatus = 0` means a clean exit (status 0) is treated as
  intentional and the unit is not restarted; any failure restarts after 5s.
