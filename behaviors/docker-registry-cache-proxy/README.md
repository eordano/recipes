# docker-registry-cache-proxy

Point **both** rootful and rootless Docker at a pull-through registry cache
whose TLS is terminated with a **self-signed CA** — and get the trust chain in
place *before* the daemon starts.

## Problem

You run a caching pull-through registry proxy (e.g. a `registry:2` in
`proxy` mode, or Harbor/Zot) so your hosts don't re-download the same Docker
Hub layers over and over. The proxy serves HTTPS with a private CA. You now
need every Docker daemon on your fleet to:

1. route registry pulls through the proxy, and
2. trust the proxy's CA — including for the upstream hostnames the daemon
   *thinks* it is contacting.

Naively dropping the CA into the system trust store (or into a oneshot that
runs "sometime during boot") does not reliably work. Two things bite you.

## The traps

**1. `certs.d/` is keyed by the registry the daemon addresses, not by the
proxy.** Docker looks for a per-registry CA under
`/etc/docker/certs.d/<host:port>/ca.crt`. When you configure Docker Hub through
a proxy, the daemon still resolves Hub as two distinct endpoints:

- `registry-1.docker.io` — the image/data endpoint
- `registry.docker.io` — the auth/index endpoint

So the CA must be installed in **three** `certs.d/` directories: the proxy's
own `host:port`, **and** both `registry-1.docker.io` and `registry.docker.io`.
Miss either Hub hostname and pulls fail with x509 errors even though the proxy
cert is "trusted" everywhere else.

**2. The CA must be trusted *before* `docker.service` starts.** If Docker comes
up first, its first pull fails and the failure can stick. The setup unit is
therefore ordered `Before=docker.service` and pulled in by
`WantedBy=docker.service`.

**3. The network may not be up when the setup unit runs.** Even with
`After=network-online.target`, the CA host can be briefly unreachable at boot.
The unit fetches `ca.crt` in a **retry loop** (default 30 attempts, 2s apart)
and only fails after exhausting them, with `Restart=on-failure` as a backstop.

## What the module does

- Sets `HTTP_PROXY` / `HTTPS_PROXY` (and `NO_PROXY=localhost,127.0.0.1`) on the
  Docker service, plus `virtualisation.docker.daemon.settings.proxies`.
- Points `SSL_CERT_FILE` at a merged bundle (system CAs + the cache CA).
- Runs `docker-ca-setup` (oneshot, before Docker): downloads the CA with the
  retry loop and installs it into all three `certs.d/` directories plus the
  merged bundle.
- Optionally repeats the whole thing for **rootless** Docker as a
  `systemd.user` service, writing `~/.config/docker/certs.d/...` and patching
  `~/.docker/config.json` proxies (backing up any existing file first).

## Usage

```nix
{
  imports = [ ./docker-registry-cache-proxy ];

  behaviors.docker-cache = {
    enable   = true;
    cacheUrl = "https://docker-cache.example.com";  # your pull-through cache
    # proxyPort      = 3128;         # HTTP proxy port on the cache host (default)
    # caCertPath     = "/ca.crt";    # path on cacheUrl that serves the CA
    # caCertSha256   = null;         # pin the CA by hash (recommended, see below)
    # maxAttempts    = 30;           # CA-download retries before failing
    # enableRootless = true;         # also wire rootless per-user Docker
  };
}
```

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Turn the behavior on. |
| `cacheUrl` | *(required)* | Base URL of the pull-through cache; its CA is fetched from here. |
| `proxyPort` | `3128` | Port on the cache host speaking the proxy/registry protocol. |
| `caCertPath` | `/ca.crt` | Path, relative to `cacheUrl`, that serves the CA cert. |
| `caCertSha256` | `null` | Optional lowercase-hex SHA-256 of the CA PEM; when set, the download is verified and install fails closed on mismatch. |
| `maxAttempts` | `30` | CA-download retries before the oneshot fails. |
| `enableRootless` | `true` | Also install CA + proxy config for rootless (per-user) Docker. |

## Caveats

- The `caCertPath` endpoint must serve the raw PEM CA to an unauthenticated
  client at boot — the retry loop has no credentials.
- The rootless variant assumes a per-user systemd session and writes into the
  user's `$HOME`. It patches `~/.docker/config.json`; a pre-existing file is
  copied to `config.json.bak` first.
- The daemon proxy settings send *all* Docker HTTP(S) traffic through the proxy
  except `localhost,127.0.0.1`. If you need other no-proxy hosts, extend the
  module.

## Security notes

- **This is the trust bootstrap for your whole registry chain.** The fetched CA
  is installed as a trusted anchor for the *real* Docker Hub hostnames
  (`registry-1.docker.io`, `registry.docker.io`), so whoever controls that CA
  can serve any image layer to every host. Treat the CA and the cache host as
  fleet-critical, and trust a self-signed CA fleet-wide only if you accept that.
- **The boot-time CA fetch is only as trustworthy as its transport.** If you set
  `cacheUrl` to `http://`, or to `https://` with a serving cert nothing here
  validates, an on-path attacker can hand back their *own* CA and Docker will
  then trust attacker-signed certs for Docker Hub. Serve the CA over TLS with a
  publicly-trusted serving cert **and/or** pin it with `caCertSha256` (compute
  it with `sha256sum ca.crt`); the pin makes the module fail closed on any
  mismatch. Leaving `caCertSha256 = null` keeps the older unpinned behavior.
- The CA is staged in a private `mktemp` file (random name, `0600`, `PrivateTmp`
  on both setup units) rather than a fixed `/tmp` path, so it is not a
  cross-user pre-seed or symlink-TOCTOU target on multi-user hosts.
