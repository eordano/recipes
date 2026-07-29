# jellyfin-vaapi-container

Run Jellyfin inside a NixOS declarative container that is network-isolated on a
private veth pair — only the host's nginx reverse proxy can reach it — while
still getting **Intel VA-API hardware transcoding** by passing the host's DRM
render nodes into the container.

## The problem

You want two things that pull in opposite directions:

1. **Isolation.** Jellyfin is a large media server with a plugin system; you'd
   rather it not sit directly on your LAN or have unrestricted network access. A
   NixOS container with `privateNetwork = true` gives it a private veth pair
   reachable only by the host — nothing else can dial `:8096`.

2. **Hardware transcoding.** VA-API transcoding needs the GPU. But a
   `privateNetwork` container is deliberately locked down, and its device cgroup
   blocks the DRM device nodes by default. Isolation and GPU access seem
   mutually exclusive.

## The insight

Network isolation and device access are independent knobs. You can keep the
container off the network **and** hand it the GPU:

- **`/dev/dri` bind mount** makes the device files visible inside the container.
- **`allowedDevices`** whitelists the specific nodes (`renderD128`, `card0`)
  through the container's device cgroup — the bind mount alone is not enough;
  without the whitelist the cgroup still denies access.
- **`hardware.graphics` + Intel drivers inside the container** provide the
  userspace VA-API stack. The device nodes come from the host, but the drivers
  that talk to them must live in the container.
- **`render` + `video` groups** on the container's `jellyfin` user grant it
  permission to open those nodes.

All four pieces are required together. Drop any one and transcoding fails
silently (Jellyfin falls back to slow software transcoding, or errors).

nginx on the host terminates TLS and proxies to the container's veth address, so
the outside world only ever talks to nginx.

## The escape hatch

Sometimes the container itself needs outbound internet — most commonly to
download Jellyfin plugins, which a fully private container cannot do.

`allowExternalConnections = true`:

- drops `privateNetwork`, giving the container its own route out, and
- repoints nginx from the veth address to `127.0.0.1` (since without the private
  veth the container is reachable on the host loopback instead).

Leave it `false` for the isolated-by-default posture; flip it on only when you
need it, then flip it back.

> **Security note.** With `allowExternalConnections = true` the container shares
> the host network namespace and Jellyfin binds `0.0.0.0:8096`. To keep it off
> the LAN this module drops `:8096` from the firewall in that mode, so only
> loopback (nginx's TLS front-end) reaches it. Don't re-open `:8096` on the host
> firewall while the hatch is on, or you expose plaintext Jellyfin on every
> interface, bypassing the reverse proxy.

## Usage

```nix
{
  imports = [ ./jellyfin-vaapi-container ];

  modules.jellyfin = {
    enable   = true;
    domain   = "jellyfin.example.com";  # nginx vhost
    acmeHost = "example.com";           # cert served via useACMEHost
    mediaDir = "/srv/media";
  };
}
```

Configure the ACME certificate itself with `security.acme` elsewhere; this
module only references it via `useACMEHost`.

### Options

| Option | Default | Notes |
| --- | --- | --- |
| `enable` | `false` | Turn the whole thing on. |
| `domain` | (required) | FQDN for the nginx virtual host. |
| `acmeHost` | (required) | ACME host whose cert nginx serves. |
| `dataDir` | `/srv/jellyfin/data` | Persistent state, bind-mounted to `/data`. |
| `mediaDir` | `/srv/jellyfin/media` | Library, bind-mounted read-write to `/media`. |
| `containerNetwork.hostAddress` | `192.168.200.1` | Host side of the veth pair (RFC1918; change on subnet clash). |
| `containerNetwork.localAddress` | `192.168.200.2` | Container side of the veth pair. |
| `uid` / `gid` | `1304` | System user for jellyfin. Arbitrary — just keep it stable across rebuilds. |
| `graphicsPackages` | `[ ]` | Extra GPU drivers for non-Intel hardware. |
| `nameservers` | `[ "1.1.1.1" ]` | Resolvers inside the container. |
| `allowExternalConnections` | `false` | Escape hatch — see above. |

## Caveats and gotchas

- **The bind mount is not enough by itself.** You need `allowedDevices` too, or
  the container's device cgroup blocks the DRM nodes. This is the trap the whole
  recipe exists to document.
- **Device node names are host-specific.** `renderD128` / `card0` are the common
  case, but a host with multiple GPUs (or a discrete card) may enumerate them as
  `renderD129`, `card1`, etc. Check `ls /dev/dri` on the host and adjust
  `allowedDevices`.
- **Intel-only drivers ship by default.** For AMD or Nvidia, add the appropriate
  userspace packages via `graphicsPackages`; the Intel packages are always
  included.
- **`uid`/`gid` must stay stable.** The persisted `dataDir` is chowned to this
  UID. Changing it after first run orphans the existing state files. The default
  `1304` is arbitrary — any free UID works, it just needs to be constant.
- **The container is named `media`,** not `jellyfin` — that is what you pass to
  `machinectl` / `nixos-container` and what `systemd-nspawn@media.service` is
  called. It is a fixed name, so you cannot run two instances of this module on
  one host without editing it.
- **`stateVersion` is pinned to `24.11`** inside the container. This is
  intentional — a container's `stateVersion` should not track the host's. Bump
  it only when you understand the migration implications.
