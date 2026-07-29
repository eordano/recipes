# tailscale-derp-server

A NixOS module that self-hosts a [Tailscale DERP](https://tailscale.com/kb/1232/derp-servers)
relay behind nginx, with ACME certificates and abuse filtering.

## What problem it solves

DERP is Tailscale's relay of last resort: when two nodes can't establish a
direct WireGuard path (symmetric NAT, restrictive firewalls), their encrypted
packets bounce through a DERP relay instead. Running your own relay keeps that
traffic on your own infrastructure rather than Tailscale's public DERP mesh,
and — fronted on port 443 — it works through corporate firewalls that block
non-standard ports.

NixOS ships no DERP module, so this wraps the `derper` binary (from
`pkgs.tailscale.derper`) into a hardened systemd service plus an nginx reverse
proxy.

## The insight & the traps

The value here is the wiring, not the binary. Several things are non-obvious:

- **`-certmode=manual` fed by symlinks.** derper's default cert mode wants to
  run its own LetsEncrypt autocert. Instead we let NixOS's ACME manage the
  cert and hand derper the files. ACME and derper disagree on filenames, so an
  `ExecStartPre` symlinks `fullchain.pem`/`key.pem` to the `<hostname>.crt`/
  `.key` names derper expects.

- **Nothing runs as root — not even the setup step.** The obvious way to write
  that `ExecStartPre` is with systemd's `+` prefix so it can `chown` freely.
  That is unnecessary: `StateDirectory=derper` already creates the state
  directory owned by the service user, and the certificate is reachable by
  joining the group that owns it. Dropping the prefix also makes the
  readability check *real* — as root, `test -r` always succeeds and has to be
  faked with `su`, which silently tests the wrong thing if the user's groups
  are wrong. Run as the service user and the check is the same access the
  daemon will perform a second later, so a group misconfiguration fails the
  unit immediately with a clear message rather than surfacing minutes later as
  a TLS handshake error.

- **The owning group is derived, not assumed.** It is tempting to hardcode
  `nginx`, since a web server usually provisions the cert. But that group is a
  property of the *certificate*, not of this module: it comes from
  `security.acme.certs.<dir>.group`, whose NixOS default is `acme`. The module
  reads that value and joins whatever it actually is, and asserts at build time
  that it could determine it — so a mismatch is a build error with a fix in the
  message, never a running relay that cannot read its own key.

- **Poll for the cert.** The unit orders `after` the
  `acme-finished-<host>.target`, but the files can still lag that target. The
  `ExecStartPre` polls up to ~60s for them before symlinking — without the
  loop, a race leaves derper starting with no cert.

- **HTTP/2 must be OFF on the nginx vhost.** DERP negotiates over HTTP/1.1
  `Upgrade` semantics; leaving HTTP/2 on breaks the relay handshake.

- **Only proxy the real DERP endpoints; 444 everything else.** The vhost
  enumerates exactly `/derp` (websocket, with 10-minute timeouts),
  `/derp/probe`, `/derp/latency-check`, `/generate_204`, `/robots.txt`, and
  `/bootstrap-dns`. Any other path hits `location "/"`, gets logged to a
  probes log, and returns `444` (nginx closes the connection with no
  response). This keeps the box from looking like a live web server to
  internet scanners.

- **Gate clients to your tailnet with `-verify-clients`.** Without it your
  relay is an open DERP anyone can bounce traffic through. With it, derper
  checks each client against the local Tailscale daemon (which must be
  running on the host).

- **Split-port trap.** All the nginx and fail2ban machinery is gated on
  `port != 443`. If you run derper *directly* on 443 (no reverse proxy), the
  vhost and jails silently vanish — that's intentional, but surprising.

- **Backend SSL verify off + buffering off.** nginx talks to derper over
  loopback HTTPS; `proxy_ssl_verify off` avoids validating the loopback cert,
  and buffering off keeps long-lived relay streams from stalling.

## Certificate setup

The module reads a cert from `/var/lib/acme/<acmeHost or hostname>/`. You still
have to arrange for that cert to exist; the module works out who may read it.

Nothing in this module runs as root, so access is purely by group membership.
The module looks up the matching `security.acme.certs` entry and adds the
`derper` user to that certificate's `group` — whatever it is. Declare the cert
however you normally would:

```nix
security.acme.certs."derp.example.com".group = "nginx";
```

The NixOS default for that option is `acme`, not `nginx`; either works, since
the group is read rather than assumed. When nginx fronts the relay you will
usually want `nginx` anyway so the proxy can read the same files, and the
`nginx` gid is pinned (via `mkDefault`) so it is stable on minimal hosts.

If the certificate is provisioned outside the NixOS ACME module there is
nothing to look up, and the build fails with an assertion telling you to name
the group yourself:

```nix
services.derp-server.acmeGroup = "some-group";
```

## Usage

```nix
{
  imports = [ ./modules/tailscale-derp-server ];

  services.derp-server = {
    enable   = true;
    hostname = "derp.example.com";   # MUST match the served TLS cert
    port     = 8443;                 # derper listener; nginx proxies 443 -> here
    stunPort = 3478;
    verifyClients = true;            # gate to your tailnet
    # acmeHost = "example.com";      # if a different-named cert covers hostname
  };

  # Optional: ban scanners (needs services.fail2ban.enable = true)
  services.derp-server.fail2ban.enable = true;
}
```

Then point your Tailscale/Headscale control plane at the relay in your DERP
map (region with `HostName = "derp.example.com"`, `DERPPort = 443`,
`STUNPort = 3478`).

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `hostname` | *(required)* | DERP hostname; **must** match the TLS cert. |
| `port` | `8443` | derper's own HTTPS listener. `443` = run direct, no nginx. |
| `stunPort` | `3478` | STUN port (opened on the firewall). |
| `verifyClients` | `true` | Pass `-verify-clients`; restrict relay to your tailnet. |
| `acmeHost` | `null` → `hostname` | Which `/var/lib/acme/<dir>` cert to read. |
| `acmeGroup` | `null` → cert's own group | Group owning the ACME files, which `user` joins to read them. Auto-detected from `security.acme.certs.<dir>.group`; set only when the cert is provisioned outside the ACME module. |
| `user` / `group` | `derper` | System user/group derper runs as. Never root. |
| `fail2ban.enable` | `false` | Register the probe + bad-TLS jails (needs nginx + `services.fail2ban`). |
| `fail2ban.action` | `null` | fail2ban action for the jails; `null` = global default. |
| `fail2ban.bantime` | `"168h"` | Ban duration. |

## fail2ban jails

When `fail2ban.enable` is set (and nginx is fronting derper), two jails are
registered with matching `/etc/fail2ban/filter.d` filters:

- **`derp-probes`** — bans IPs that trip the nginx `444` responses (i.e. hit
  paths that aren't real DERP endpoints), read from
  `/var/log/nginx/derp-probes.log`.
- **`derp-bad-tls`** — bans IPs producing `cert mismatch` TLS handshake
  errors in the derper journal.

Leave `fail2ban.action` at `null` to use fail2ban's global `banaction`, or set
it to a named action of your own.

## Security notes

The systemd unit is tightly sandboxed: `ProtectSystem=strict`,
`ProtectHome=true`, `NoNewPrivileges=true`, `/var/lib/acme` mounted read-only,
and the capability set narrowed to just `CAP_NET_BIND_SERVICE` (the ambient
cap that lets the unprivileged user bind the low STUN/relay ports).

No step in the unit runs as root, including `ExecStartPre` — the service user
is `derper` throughout, and two build-time assertions keep it that way: one
rejects `user = "root"`, the other refuses to build unless the owning group of
the ACME material could be determined.
