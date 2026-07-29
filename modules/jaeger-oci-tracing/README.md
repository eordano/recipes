# jaeger-oci-tracing

Run [Jaeger](https://www.jaegertracing.io/) distributed tracing as an OCI/Docker
container on NixOS, with the UI behind nginx+TLS and the OTLP ingest ports left
raw for trusted collectors.

## The problem

There is no native nixpkgs service for Jaeger, so it runs as a container. A
tracing backend has two very different network surfaces, and treating them the
same gets you either a broken UI or an open door:

- **The UI (port 16686)** is a web app. It wants TLS and a domain, so it goes
  through nginx like any other web service. Its container port is published on
  `127.0.0.1`, so it is reachable **only** through the nginx TLS vhost — never
  as raw plaintext HTTP on an external interface.
- **The OTLP ingest ports (4317 gRPC, 4318 HTTP)** are where your services push
  spans. They are *unauthenticated*. Proxying them through nginx buys nothing
  and adds latency; what they need is to be reachable **only from your
  collectors** — a VPN, a private subnet, a trusted interface — never the public
  internet. They are published on `otlpListenAddress`, which defaults to
  loopback; point it at a trusted-network interface to reach the host remotely.

So the module deliberately splits the surface: nginx proxies the UI only, and
the OTLP ports are published on a bind address you control.

> **Docker bypasses the NixOS firewall.** Docker publishes container ports with
> a DNAT rule in the `DOCKER` iptables chain that skips the
> `networking.firewall` INPUT chain. So what actually determines exposure is the
> *publish bind address* (`127.0.0.1` for the UI, `otlpListenAddress` for OTLP),
> **not** `openFirewall`. A `0.0.0.0` bind is reachable on every interface
> regardless of the firewall toggle. This is why the defaults bind to loopback.

## The traps this encodes

1. **The docker network must be created before the container starts.** The
   container joins a named docker network. NixOS's generated `docker-jaeger`
   unit has no idea that network needs to exist first, so a `docker-network-jaeger`
   oneshot (`Type = "oneshot"`, `RemainAfterExit = true`) creates the network
   and is ordered `before` the container, which `requires` it. Drop the
   ordering and, on boot, the container comes up attached to nothing.

2. **Enabling without a UI domain fails eval, on purpose.** `domain` is asserted
   non-null. Without the assertion, forgetting to set it would silently leave
   the UI with no nginx vhost — reachable only on loopback — with no error to
   tell you why.

3. **The OTLP ports are unauthenticated.** They default to a loopback bind
   (`otlpListenAddress = "127.0.0.1"`), so out of the box nothing off-host can
   reach them. To let remote collectors in, set `otlpListenAddress` to a
   trusted-network interface address (VPN / private subnet). Because Docker's
   published-port DNAT bypasses the NixOS firewall, this bind address — not
   `openFirewall` — is what governs exposure. `openFirewall` defaults to `false`
   and only opens the OTLP ports in the firewall INPUT chain; enable it only
   where the network already restricts those ports to trusted collectors.

## Usage

Import the module and enable it:

```nix
{
  imports = [ ./modules/jaeger-oci-tracing ];

  modules.services.jaeger = {
    enable   = true;
    domain   = "jaeger.example.com";  # UI vhost (required)
    acmeHost = "example.com";         # cert to reuse, or null
    image    = "jaegertracing/all-in-one:latest";

    # OTLP ingest binds to loopback by default. To accept spans from other
    # hosts, publish it on a trusted-network interface (VPN / private subnet):
    # otlpListenAddress = "10.0.0.1";
  };
}
```

Browse the UI at `https://jaeger.example.com`. With the default
`otlpListenAddress`, OTLP ingest is loopback-only — point exporters running on
the same host at `127.0.0.1:4317` (gRPC) or `127.0.0.1:4318` (HTTP). To ingest
from other hosts, set `otlpListenAddress` to a trusted-interface IP and point
exporters at that address.

### Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `domain` | `null` | UI vhost domain. **Required** (asserted non-null). |
| `acmeHost` | `null` | ACME host whose cert the vhost reuses (`useACMEHost`); `null` to manage TLS elsewhere. |
| `image` | `jaegertracing/all-in-one:latest` | OCI image reference. |
| `imageFile` | `null` | Pre-built image tarball (e.g. a pinned `dockerTools.pullImage`) to load instead of pulling `image`. |
| `user` / `group` | `jaeger` | System user/group owning the data dir. |
| `uid` / `gid` | `1322` | IDs for that user/group. |
| `dataDir` | `/var/lib/jaeger` | Data directory (created `0700`). |
| `uiPort` | `16686` | Host port for the UI (proxied). |
| `otlpGrpcPort` | `4317` | Host port for OTLP gRPC ingest (raw). |
| `otlpHttpPort` | `4318` | Host port for OTLP HTTP ingest (raw). |
| `network` | `jaeger` | Docker network name the container joins. |
| `otlpListenAddress` | `127.0.0.1` | Host interface the OTLP ports are published on. Loopback by default; set to a trusted-interface IP for remote collectors. Governs exposure (Docker DNAT bypasses the firewall). |
| `openFirewall` | `false` | Open the OTLP ports in the firewall INPUT chain (opt-in; partial control — see the Docker/firewall note). The UI is never opened raw. |

### Pinning the image

For reproducible deploys, build the image tarball with
`pkgs.dockerTools.pullImage` (or your own `buildImage`) and pass it as
`imageFile`; the container runtime loads it instead of pulling by reference:

```nix
modules.services.jaeger.imageFile = pkgs.dockerTools.pullImage {
  imageName = "jaegertracing/all-in-one";
  imageDigest = "sha256:...";
  sha256 = "...";
};
```

## Caveats

- Requires `virtualisation.docker.enable = true` and an nginx that serves the
  configured vhost.
- The `all-in-one` image keeps traces in memory by default; for retention,
  switch to a Jaeger image backed by a persistent store and mount `dataDir`.
- OTLP ingest is unauthenticated — see trap 3.
