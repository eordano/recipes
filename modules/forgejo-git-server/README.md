# forgejo-git-server

A NixOS module for self-hosting [Forgejo](https://forgejo.org/) behind an nginx
TLS front-end. It supports two deployment shapes behind one option set:

- **Container** (`asContainer = true`, default): a podman container built from a
  locally-assembled OCI image, running as a non-root uid inside, optionally on a
  sandboxed runtime such as gVisor/`runsc`. (The podman unit itself is an
  ordinary root-run system service — `virtualisation.oci-containers` has no
  rootless mode.)
- **Native** (`asContainer = false`): NixOS's built-in `services.forgejo`,
  typically over a unix socket.

Both share the same nginx vhost, database wiring, and optional OIDC login-source
bootstrap.

The image is assembled from your nixpkgs' `pkgs.forgejo`, so the version you get
is whatever that pin ships (15.x or newer).

Most of this module is not glue — it is a set of hard-won workarounds for the
stricter startup checks Forgejo introduced in 15.x, and for git smart-HTTP over
a reverse proxy. The traps are the point.

## The traps this encodes

### 1. `RUN_USER` must match the in-container passwd name, or startup dies

Since 15.x, Forgejo's "current run user matches config" check is **fatal**. In a
container the process runs as a numeric uid that has no name unless you give it
one. The module ships a synthetic `/etc/passwd` (`containerEtc`) that names the
container uid `root`, and hardcodes `RUN_USER = root` to match. Change one
without the other and Forgejo refuses to boot. If you re-point the container to
a different uid, the passwd entry regenerates automatically — but the *name*
stays `root` on purpose.

### 2. Externally-added SSH keys abort boot unless you allow them

Since 15.x, Forgejo hard-fails at startup if `.ssh/authorized_keys` contains any key
not present in its database (`modules/ssh/init.go`). If anything ever added a
key out-of-band — a CI runner, a mirror/backup daemon that pulls over
git-over-ssh — the new check flags it as "unexpected" and aborts. The upstream
suggestion to just delete the file would drop those keys and can lock out
legitimate fetchers. This module sets
`SSH_ALLOW_UNEXPECTED_AUTHORIZED_KEYS = true` instead: the keys still
authenticate, only the startup consistency assertion is disabled.

### 3. `proxy_buffering off` is load-bearing for remote git clones

With nginx's default `proxy_buffering on`, nginx buffers the entire git
`upload-pack` response and **truncates the tail** when flushing to a client with
non-zero latency. The clone or fetch dies with:

```
fatal: early EOF
fatal: unexpected disconnect while reading sideband packet
```

The insidious part: **loopback clients are unaffected**, so it works perfectly
on the box and only fails for real remote clients over the network. The module
sets `proxy_buffering off` and `proxy_request_buffering off` on the git vhost.
Do not "clean this up."

### 4. The DB password never enters the Nix store

`app.ini` ships with a literal `` `FORGEJO_DB_PASSWD` `` placeholder. At deploy
time the container's `preStart` reads the password from `database.passwordFile`
and `sed`-substitutes it into a rendered `app.ini` inside the data volume, then
`chmod 600`s it. The Nix-store copy only ever contains the placeholder, so the
secret is never world-readable in `/nix/store` and never in your git history.

### 5. uid/gid pinning for persistent repo storage

If repositories live on persistent storage whose ownership must survive
rebuilds, pin `uid`/`gid`. A silent uid drift will leave Forgejo unable to read
its own repositories.

## Usage

Import the module and enable it. Minimal SQLite example:

```nix
{
  imports = [ ./forgejo-git-server ];

  modules.forgejo = {
    enable = true;
    domain = "git.example.com";
    acmeHost = "git.example.com";   # references security.acme.certs.<name>
    database.type = "sqlite3";
  };
}
```

Postgres, container shape, with a secret file:

```nix
modules.forgejo = {
  enable = true;
  asContainer = true;
  domain = "git.example.com";
  acmeHost = "git.example.com";
  uid = 990;
  gid = 990;

  database = {
    type = "postgres";
    host = "127.0.0.1";
    name = "forgejo";
    user = "forgejo";
    passwordFile = "/run/secrets/forgejo-dbpassword";
    configureLocalAuth = true;   # add local peer/ident rules to services.postgresql
  };

  # Optional: stronger container isolation. You must install/register the
  # runtime on the host yourself.
  containerRuntime = "runsc";   # gVisor
};
```

Advertise SSH clone URLs while the host's openssh actually serves them (a common
setup — a `git`/`gitea` user with forced-command `authorized_keys`):

```nix
modules.forgejo = {
  # ...
  sshPort = 22;      # port shown in clone URLs
  sshUser = "git";   # user shown in clone URLs
  sshBuiltin = false; # do NOT run Forgejo's built-in sshd; host openssh serves it
};
```

To instead run Forgejo's bundled SSH server inside the container, set
`sshBuiltin = true` (the firewall port is opened automatically).

### OIDC

Setting `oidc.enable = true` installs a oneshot unit that waits for both Forgejo
and the OIDC discovery endpoint to come up, creates the OAuth login source via
`forgejo admin auth add-oauth` (idempotent), and flips `is_sync_enabled` in the
`login_source` table to enable auto-registration.

```nix
modules.forgejo.oidc = {
  enable = true;
  discoveryUrl = "https://idp.example.com/realms/main/.well-known/openid-configuration";
  clientId = "forgejo";
  clientSecretFile = "/run/secrets/forgejo-oidc-secret";
  groupClaimName = "groups";
  adminGroup = "forgejo-admins";
};
```

Note: the `is_sync_enabled` flip is issued via `psql` against a Postgres
backend; it is a no-op / harmless failure on other engines.

**Secret handling.** The OIDC client secret is read from `clientSecretFile` at
runtime and is never written to the systemd journal — the setup unit does not
echo it and does not dump the `login_source.cfg` column (which stores the
secret) to stdout. It is, however, passed to `forgejo admin auth add-oauth`
via `--secret`, because Forgejo's CLI accepts the client secret only as a
command-line argument (there is no env-var, stdin, or `--secret-file` input
upstream). It is therefore briefly present in `/proc/<pid>/cmdline` for the
lifetime of that one exec, running as the unprivileged `forgejo` user. On a
multi-tenant host where other local users must not observe it, mount `/proc`
with `hidepid=2`.

## Key options

| Option | Default | Purpose |
|---|---|---|
| `enable` | `false` | Turn the module on. |
| `appName` | `Forgejo: Beyond Coding. We Forge.` | `APP_NAME` shown in the UI. |
| `domain` | — (required) | Public domain; drives `ROOT_URL` and the nginx vhost. |
| `acmeHost` | `null` | ACME cert name for TLS; `null` leaves TLS unconfigured. |
| `asContainer` | `true` | Podman-container shape vs. native `services.forgejo`. |
| `httpPort` | `3000` | Internal HTTP port behind nginx. |
| `dataDir` | `/var/lib/forgejo` | State directory (`/data` inside the container). |
| `uid` / `gid` | `null` | Pin service uid/gid for stable on-disk ownership. |
| `containerRuntime` | `null` | podman `--runtime` (e.g. `runsc` for gVisor). |
| `containerExtraOptions` | `[ "--network=host" ]` | Extra podman run flags. |
| `useUnixSocket` | `true` | Native shape: unix socket vs. TCP. |
| `unixSocket` | `/run/forgejo/forgejo.sock` | Socket path for the native unix-socket shape. |
| `sshPort` / `sshUser` / `sshBuiltin` | `null` / `git` / `false` | SSH clone-URL display vs. actually serving SSH. |
| `theme.default` / `theme.list` | `forgejo-auto` / `forgejo-auto,forgejo-light,forgejo-dark` | UI theme defaults (container shape's `app.ini`). |
| `database.*` | sqlite3 | Engine, connection, `passwordFile`, `sslMode`, `socket`, `path`, `createDatabase`, `configureLocalAuth`. |
| `oidc.*` | disabled | Auto-configure an OpenID Connect login source (`discoveryUrl`, `clientId`, `clientSecretFile`, `scopes`, `authSourceName`, `groupClaimName`, `adminGroup`, `restrictedGroup`). |

## Caveats

- The container shape uses `--network=host` by default so nginx's loopback
  `proxyPass` reaches the container. The container binds its plaintext HTTP
  listener to `127.0.0.1`, so the unauthenticated, TLS-less port is not reachable
  off-box even if you loosen the firewall — all outside traffic must go through
  the nginx TLS front-end. If you switch `containerExtraOptions` to an isolated
  container network you must change the app.ini `HTTP_ADDR` back to `0.0.0.0` and
  repoint the proxyPass accordingly.
- `SSL_MODE` defaults to `disable`, which assumes the database is local
  (loopback or unix socket). If you set `database.host` to a remote DB, also set
  `database.sslMode` (e.g. `"require"`) so the DB password and repo metadata are
  not sent in cleartext. This applies to the container shape; the native shape
  inherits the upstream `services.forgejo` default.
- **The module appends to the host's `sshd_config` unconditionally.** Enabling it
  adds a `Match User forgejo` block setting `PubkeyAuthOptions none`, so
  `authorized_keys` forced-commands behave predictably when git-over-ssh is
  routed through the host's openssh. That happens in both shapes, whether or not
  you use SSH cloning.
- `configureLocalAuth` writes to the host's upstream `services.postgresql`
  `authentication`/`identMap`. If you already manage those elsewhere, leave it
  `false` to avoid conflicts.
- Sandboxed runtimes (`runsc`) must be installed and registered with podman on
  the host; this module only passes the `--runtime` flag.
- The option namespace is `modules.forgejo` (not `services.forgejo`), chosen to
  avoid colliding with the upstream NixOS module it can delegate to.
