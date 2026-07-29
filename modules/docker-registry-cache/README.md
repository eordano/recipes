# docker-registry-cache

A NixOS module that runs a **LAN-wide pull-through cache for Docker/OCI
registries** on top of
[rpardini/docker-registry-proxy](https://github.com/rpardini/docker-registry-proxy).
Point every Docker daemon on your network at one host; each layer blob is
pulled from upstream once and then served from local disk.

## The problem

Every developer laptop, CI runner, and Kubernetes node re-pulls the same
base images. It's slow, it burns bandwidth, and it runs you into Docker
Hub rate limits. A shared caching proxy fixes all three — but the good one
(rpardini's) works by **intercepting HTTPS**, and that intercept is where
every naive setup breaks.

## The key insight (and four traps)

rpardini terminates TLS to the upstream registries using a **CA it
generates itself on first run**. That is what lets it cache layers that
would otherwise be encrypted end-to-end. It also means the setup only
works if you get four fiddly things right — which is the entire reason
this module exists:

1. **Clients must trust the intercept CA, so you have to hand it out.**
   Until a client trusts the proxy's CA, every pull dies with a
   certificate error. The module serves the CA over nginx at `/ca.crt`, so
   onboarding a client is a single `curl`. (This is a *different*
   certificate from the public ACME cert nginx uses for the front-end —
   don't confuse the two.)

2. **The CA export races the container's cold boot.** The proxy writes its
   CA into the `/ca` volume *only after* it has started for the first
   time. A oneshot that just copies the file will run before the file
   exists. The `docker-registry-proxy-ca-export` unit therefore polls (up
   to 60s) for both the container *and* the CA file, is ordered
   `After`/`Wants` the proxy units, and uses `Restart=on-failure` so a
   too-early first run just retries.

3. **Credentials must never hit disk in expanded form.** You provide
   registry logins in a friendly `host:user:pass` file. The module
   converts that to rpardini's space-separated `AUTH_REGISTRIES` variable
   **at `preStart`, writing it only into `/run` (tmpfs)** as an env-file.
   The expanded secret is never written to persistent storage and never
   enters the Nix store. The env-file is created mode `0600` (root-only)
   because `/run` is world-readable, so on a multi-user host local accounts
   cannot read the expanded credentials.

4. **Buffering multi-GB layers will kill you.** Image layers routinely run
   to gigabytes. If nginx buffers requests/responses it spools them to
   disk and times out. The front-end disables all of it —
   `client_max_body_size 0`, `proxy_request_buffering off`,
   `proxy_buffering off` — plus 900s read/send timeouts for slow links, so
   layers stream straight through.

## Requirements

- Docker enabled (`virtualisation.docker.enable = true;`) — the module
  uses the `docker` oci-containers backend.
- nginx enabled (`services.nginx.enable = true;`).
- A DNS name pointing at the host, and (by default) ACME configured for
  automatic TLS on the front-end.

## Usage

```nix
{
  imports = [ ./modules/docker-registry-cache ];

  modules.services.docker-registry-cache = {
    enable = true;
    domain = "docker-cache.example.com";

    # Optional: point the cache at a big/dedicated filesystem.
    cacheDir = "/var/lib/docker-registry-cache";
    maxSize  = "200g";

    # Optional: authenticate to private/rate-limited registries.
    # Provide this path via your secrets tool — NOT the Nix store.
    authConfigFile = "/run/secrets/docker-cache-auth";
  };
}
```

### Auth file format

One line per registry, colon-separated. Omit registries that need no auth.

```
docker.io:myuser:mypassword
quay.io:myuser:mytoken
gcr.io:_json_key:{"type":"service_account",...}
```

### Pointing clients at the cache

On each client, trust the intercept CA and route the daemon through the
proxy:

```bash
# 1. Fetch the proxy's intercept CA and add it to the SYSTEM trust store
#    (not /etc/docker/certs.d — that is for talking to a registry directly,
#    the intercept has to be trusted host-wide so dockerd's TLS validates).
curl -s https://docker-cache.example.com/ca.crt \
  | sudo tee /usr/local/share/ca-certificates/docker-registry-proxy.crt >/dev/null
sudo update-ca-certificates          # Debian/Ubuntu
# RHEL/Fedora: drop into /etc/pki/ca-trust/source/anchors + update-ca-trust

# 2. Send the daemon's traffic through the proxy
#    (systemd drop-in for dockerd, HTTP_PROXY/HTTPS_PROXY = the cache host)
```

See the [rpardini client docs](https://github.com/rpardini/docker-registry-proxy#usage---the-docker-clients)
for the exact daemon/systemd wiring.

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `domain` | *(required)* | FQDN nginx serves; where clients get `/ca.crt`. |
| `image` | `ghcr.io/rpardini/docker-registry-proxy:0.6.4` | Proxy image; pin what you trust. |
| `cacheDir` | `/var/lib/docker-registry-cache` | Cache + CA storage. Use a large disk. |
| `maxSize` | `100g` | Max on-disk cache size. |
| `registries` | docker.io, gcr.io, k8s.gcr.io, quay.io, ghcr.io | Upstreams to cache. |
| `authConfigFile` | `null` | `host:user:pass` credentials file (keep out of the store). |
| `port` | `3128` | Host port the container publishes (nginx fronts it on loopback). |
| `listenAddress` | `127.0.0.1` | Host address the container port binds to (the nginx vhost proxies to the same address). Keep loopback; see caveat. |
| `containerHostname` | `docker-registry-proxy` | Hostname set inside the container (also the `--add-host` self-mapping). |
| `verifySSL` | `true` | Verify upstream registry TLS. |
| `enableACME` | `true` | Request a real cert for the front-end. |
| `useACMEHost` | `null` | Reuse an existing ACME cert instead (mutually exclusive with `enableACME`). |
| `extraContainerOptions` | `[]` | Extra runtime args (e.g. more `--add-host`). |

## Caveats

- **Two different CAs.** The public ACME cert secures the nginx front-end
  (so `curl https://<domain>/ca.crt` is safe). The intercept CA served at
  `/ca.crt` is what clients must trust for the *cached pulls* to work.
- **Docker backend only.** Unit ordering and the CA-export `docker ps`
  probe assume the `docker` oci-containers backend.
- **First pull after a fresh boot may 502 briefly** while the proxy
  generates its CA and the export oneshot retries; subsequent pulls are
  fine.
- **Trusting the intercept CA is a real trust decision** — the proxy can
  see (and rewrite) everything it caches. Run it on infrastructure you
  control, for clients you control.
- **The proxy port binds to loopback by default.** rpardini's proxy speaks
  HTTP CONNECT/forward; exposed off-box it is an open relay and an SSRF
  vector. Clients reach it through the nginx `<domain>` vhost, not `:3128`.
  A Docker port publish bypasses the NixOS firewall (the rule lands in
  Docker's own iptables chain), so if you set `listenAddress` to a
  non-loopback address you must restrict access to that interface yourself
  — `networking.firewall` will not do it for you. The nginx vhost proxies to
  whatever `listenAddress` you set (a wildcard bind, `0.0.0.0` or `::`, maps
  back to loopback; IPv6 literals are bracketed), so moving the publish does
  not take the front end down with it.
