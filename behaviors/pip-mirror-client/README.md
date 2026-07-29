# pip-mirror-client

Point every host's `pip` at an internal PyPI mirror by dropping a system-wide
`/etc/pip.conf`. One small NixOS module, applied fleet-wide.

## Problem

Every machine that runs `pip install` hits the public PyPI over the WAN. That
wastes bandwidth on repeated downloads of the same wheels, and it means builds
break whenever PyPI is slow, rate-limits you, or is unreachable. Running an
internal caching mirror fixes both — but only if the clients actually use it.
The clean way to redirect *all* pip invocations on a host (every user, every
plain venv) is the system-wide config file `/etc/pip.conf`.

## Key insight / trap

The core setting is one line:

```ini
[global]
index-url=https://pypi.example.com/index/
```

- `index-url` sends package lookups to the mirror. If your mirror has a valid,
  trusted TLS certificate, that's all you need — TLS verification stays on.
- `trusted-host` is a **second, optional** setting for a mirror whose
  certificate pip does not trust by default — a private CA, a self-signed
  cert, or plain HTTP — where pip would otherwise refuse to talk to it
  (`SSLError` / "not a trusted host"). It takes a **bare hostname** (optionally
  `host:port`): no scheme, no path.

  ```ini
  [install]
  trusted-host=pypi.example.com
  ```

  **SECURITY:** `trusted-host` makes pip skip TLS certificate verification for
  that host, system-wide. Only set it when you actually need it (see below); a
  validly-certificated mirror should leave it unset.

## Usage

```nix
{
  imports = [ ./pip-mirror-client ];

  behaviors.pip-mirror.enable    = true;
  behaviors.pip-mirror.mirrorUrl = "https://pypi.example.com/index/";
  # Only for a self-signed / private-CA / plain-HTTP mirror — this disables
  # TLS verification for that host, so leave it unset for a trusted cert:
  # behaviors.pip-mirror.trustedHost = "pypi.example.com";
}
```

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `behaviors.pip-mirror.enable` | `false` | Write `/etc/pip.conf`. |
| `behaviors.pip-mirror.mirrorUrl` | *(required)* | Full index URL, incl. scheme and any path prefix, written as pip's `index-url`. |
| `behaviors.pip-mirror.trustedHost` | `""` (off) | Bare hostname for `[install] trusted-host`. **Disables TLS verification for that host** — set only for a self-signed / private-CA / plain-HTTP mirror; leave empty for a validly-certificated one. |

## Caveats

- This changes the **default** index for the whole system. A venv or command
  that passes its own `--index-url` / `PIP_INDEX_URL` still wins, and anything
  reading `/etc/pip.conf` will follow the mirror — make sure the mirror can
  reach or proxy the public index, or installs of packages it hasn't cached
  will fail.
- `trustedHost` is **off by default** so TLS verification stays on. Set it only
  when the mirror's certificate isn't trusted by pip (private CA, self-signed,
  or plain HTTP) — it disables TLS verification **for that host**, so an
  attacker on the network could impersonate the mirror and serve malicious
  wheels. Don't set it for a validly-certificated mirror, and don't point it at
  a host you don't control.
- **Don't put credentials in `mirrorUrl`.** pip accepts basic-auth in the index
  URL (`https://user:token@mirror/...`), but `mirrorUrl` is written verbatim
  into the world-readable `/etc/pip.conf` (mode 0444) and into the Nix store —
  so any local user could read the secret, and it would be copied to any binary
  cache the closure is pushed to. For an authenticated mirror, supply the
  credential out-of-band instead: a per-user `~/.netrc` or a keyring that pip
  reads, kept out of the Nix store.
- This is only the **client** half. It assumes a mirror already exists (e.g. a
  caching proxy such as [proxpi](https://github.com/EpicWink/proxpi) or
  devpi, optionally fronted by nginx for on-disk caching and stale-serving
  during upstream outages). Standing up that server is out of scope here.
