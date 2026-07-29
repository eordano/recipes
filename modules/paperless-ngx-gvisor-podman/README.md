# paperless-ngx behind gVisor + podman

Run [paperless-ngx](https://docs.paperless-ngx.com/) as a **gVisor-isolated
podman container** behind an nginx TLS reverse proxy, with dedicated
loopback Redis and host-persisted state.

## The problem

paperless-ngx ships as a container that wants Redis and a data volume. The naive
`oci-containers` setup gives you container-network isolation but a real kernel
attack surface (paperless is a large Python/Django + OCR stack processing
untrusted documents). This module puts a **gVisor sandbox (`runsc`) between the
container and the host kernel** instead of relying on the container's network
namespace for isolation.

## The key insight (and the trap)

**Isolation comes from `runsc`, not from the network namespace.** Once gVisor is
the security boundary, running the container with `--network=host` is fine — and
it is what lets the container reach a **loopback-only Redis** at `127.0.0.1`
without exposing Redis to anything else. The runtime is registered as a named OCI
runtime (`runsc-host` = `runsc --network=host`) and the container selects it with
`--runtime=runsc-host`.

Two traps this module handles for you:

1. **Ownership must be pre-seeded.** systemd-tmpfiles creates every bind-mount
   dir (`data`, `media`, `consume`, `export`) `0700` owned by `uid`/`gid`
   **before** the container starts. The image's `USERMAP_UID`/`USERMAP_GID` then
   run paperless as *that same id*. If the dirs don't exist with that owner on a
   fresh `dataDir`, first-run writes fail with permission errors.

2. **Public URL must match.** `PAPERLESS_URL` and `PAPERLESS_CSRF_TRUSTED_ORIGINS`
   are set to `https://<domain>`. Behind a reverse proxy, if these don't equal
   the URL the browser actually uses, login and CSRF break.

Ordering: when this module manages Redis, `podman-paperless` is set `after` /
`requires` `redis-paperless`, so Redis is up before paperless dials it.

## Usage

```nix
{
  imports = [ ./modules/paperless-ngx-gvisor-podman ];

  services.paperlessGvisor = {
    enable = true;
    domain = "paperless.example.com";
    # everything below is optional — shown with its default
    # dataDir = "/var/lib/paperless";
    # uid = 2800;
    # gid = 2800;
    # port = 2800;
    # image = "ghcr.io/paperless-ngx/paperless-ngx:latest";
    # acmeHost = null;         # reuse a named ACME cert; null => vhost gets its own
    # filenameFormat = "{correspondent}/{created_year}/{title}";
  };
}
```

### Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the service on. |
| `domain` | `null` (**required**) | Public host; drives the vhost, `PAPERLESS_URL`, CSRF origins. |
| `image` | `…paperless-ngx:latest` | Container image. **Unpinned by default — see caveats.** |
| `dataDir` | `/var/lib/paperless` | Host state root (bind-mounted, survives image churn). |
| `uid` / `gid` | `2800` | Id paperless runs as; bind-mount dirs are chowned to it. |
| `port` | `2800` | Host port paperless listens on (real host port — `--network=host`). |
| `redisPort` | `6379` | Loopback Redis port. |
| `bindAddress` | `127.0.0.1` | Address paperless binds (`PAPERLESS_BIND_ADDR`); loopback keeps the app behind TLS only. |
| `acmeHost` | `null` | Reuse a named ACME cert; `null` lets the vhost enable its own ACME. |
| `filenameFormat` | `null` | `PAPERLESS_FILENAME_FORMAT`; `null` keeps the image default. |
| `extraEnvironment` | `{}` | Extra env vars merged into the container. |
| `manageNginx` | `true` | Set `false` to wire your own reverse proxy to `127.0.0.1:<port>`. |
| `manageRedis` | `true` | Set `false` to point at your own Redis via `extraEnvironment`. |

## Caveats

- **`:latest` is unpinned.** The default image tag means a rebuild/redeploy
  silently pulls whatever ghcr currently publishes. Pin to a digest or version
  tag (`image = "…paperless-ngx@sha256:…"`) for reproducible deploys.
- **`port` is a real host port.** Because of `--network=host`, `port` and
  `redisPort` occupy the host's port space directly — make sure they're free and
  don't collide with other services.
- **Cleartext app port / TLS bypass.** With `--network=host`, whatever the app
  binds to is a real host bind. This module defaults `bindAddress` to `127.0.0.1`
  so paperless is reachable only through the nginx TLS front. If you set
  `bindAddress = "0.0.0.0"`, the plaintext login and document store are exposed
  on `port` on every interface, bypassing TLS/HSTS — keep that port firewalled
  and never rely on the app's own auth over plaintext. Even on loopback, any
  lower-trust process on the same host can reach the app directly.
- **gVisor overhead.** `runsc` adds syscall-interception overhead; OCR of large
  batches will be somewhat slower than a native container. That's the cost of the
  sandbox.
- **`uid`/`gid`/`port` sharing a number** in the example is just a convenience,
  not a requirement — pick any free values.
- Requires `pkgs.gvisor` to be available and your kernel to permit `runsc`
  (it uses `ptrace`/KVM platform depending on host config).

## What it configures

- `virtualisation.podman` + a `runsc-host` OCI runtime (gVisor with host net).
- `services.redis.servers.paperless` bound to `127.0.0.1` (when `manageRedis`).
- `services.nginx.virtualHosts.<domain>` with TLS + websocket proxy (when
  `manageNginx`).
- `systemd.tmpfiles` rules seeding the bind-mount dirs with correct ownership.
- The `paperless` OCI container with the env, volumes and runtime flags above.
