# self-hosted-firefox-sync

Run your own Firefox Sync server ([`syncstorage-rs`](https://github.com/mozilla-services/syncstorage-rs))
as a single self-contained container — the sync server **and** its MariaDB
backend bundled into one hand-built OCI image, fronted by nginx + ACME.

## Why not `services.firefox-syncserver`?

NixOS ships a `services.firefox-syncserver` module, but it wires syncserver to
a *host* MySQL/MariaDB via the NixOS database modules. That drags in a
system-wide database just for one small service. This recipe takes the opposite
approach: syncserver and a private MariaDB live together inside one image with a
custom entrypoint, so the whole stack is a single container with two bind-mounted
directories and nothing else on the host. The cost is a bespoke init script.

## The entrypoint pattern (boot-DB-then-exec)

The image has no init system, so the entrypoint does the sequencing by hand:

1. `mkdir`/`chown` the datadir and socket dir,
2. `mysql_install_db` on first boot only (guarded on `/var/lib/mysql/mysql`),
3. launch `mariadbd` in the **background**,
4. poll `mysqladmin ping` for up to 30s until the socket answers, aborting
   early (`kill -0` on the recorded pid) if mariadbd dies while we wait,
5. create the `syncstorage` and `tokenserver` databases (idempotent),
6. `exec` syncserver so it becomes PID 1 and gets signals/reaping right.

The `exec` on the last line matters: without it, syncserver runs as a child of
the shell and container stop signals go to the wrong process. For the same
reason the script never `wait`s on the backgrounded mariadbd — it is supposed
to outlive the shell, as a child of the exec'd PID 1.

## The three traps

### 1. uid/gid must agree in three places

This is the one that silently breaks a bind-mounted database. The `mysql` user's
uid/gid must be identical in **all three** of:

- the host `firefox-sync` user (`users.users.firefox-sync.uid`),
- the `0700` tmpfiles ownership of the data directories, and
- the `mysql` line baked into the image's `/etc/passwd` (shipped via
  `writeTextDir`, because the minimal image has no user database of its own).

The host owns the datadir at that numeric uid; inside the container `mariadbd`
runs as `mysql`, which only maps to the same files if the image's `/etc/passwd`
resolves `mysql` to that same number. Get them out of sync and MariaDB fails to
read a datadir it appears to own. The actual number is arbitrary — the module
exposes it as one `uid`/`gid` option that feeds all three spots.

### 2. syncserver has no port flag — 8000 is hardcoded

`syncserver` accepts only `--config` (a TOML file); there is no `--port` flag or
port env var. With no config it binds its compiled-in default of **8000**. So the
`port` option here is really "the port syncserver already listens on," and it must
match the nginx `proxyPass`. If you truly need a different port you must also
mount a config file setting `port = …` — changing the module option alone will
just make nginx proxy to a dead port.

### 3. `--network=host`

The container uses host networking so syncserver binds 8000 directly on the host
loopback and nginx proxies to `127.0.0.1:8000`. Keep this in mind if you run
multiple host-network containers — the ports share the host namespace.

## Usage

```nix
{
  imports = [ ./modules/self-hosted-firefox-sync ];

  modules.services.firefox-sync = {
    enable      = true;
    domain      = "example.com";        # served at ffsync.example.com
    acmeHost    = "example.com";        # an existing security.acme cert
    secretsFile = "/run/secrets/firefox-sync.env";
  };
}
```

Then point Firefox at your server: in `about:config` set
`identity.sync.tokenserver.uri` to
`https://ffsync.example.com/1.0/sync/1.5` and re-log-in to your Firefox Account.

### The secret

`secretsFile` is an environment file supplying `SYNC_MASTER_SECRET`:

```
SYNC_MASTER_SECRET=<long random string>
```

Generate one with `head -c 32 /dev/urandom | base64`. Any secrets mechanism works
(agenix, sops-nix, or a plain root-only file) — the module just needs a readable
path. Keep it stable: rotating it invalidates existing sync data.

## Options

| Option | Default | Notes |
| --- | --- | --- |
| `enable` | `false` | Turn the service on. |
| `domain` | `null` | Base domain; served at `ffsync.<domain>`. Required. |
| `acmeHost` | `null` | `security.acme` cert name for the vhost. Required. |
| `port` | `8000` | Must match syncserver's hardcoded bind port (see trap 2). |
| `dataDir` | `/var/lib/firefox-sync` | Bind-mounted at `/data`. |
| `mariadbDataDir` | `/var/lib/firefox-sync/mariadb` | Bind-mounted at `/var/lib/mysql`. |
| `uid` / `gid` | `990` | Load-bearing in three places (trap 1). Any free id. |
| `secretsFile` | — | Env file with `SYNC_MASTER_SECRET`. Required. |
| `extraPodmanOptions` | `[]` | Extra podman flags, e.g. `[ "--runtime=runsc" ]` for gVisor. |

## Hardened runtime (optional)

The module defaults to the standard `runc`/`crun` OCI runtime. If you have a
sandboxing runtime such as [gVisor](https://gvisor.dev/) registered with podman,
opt in with:

```nix
modules.services.firefox-sync.extraPodmanOptions = [ "--runtime=runsc" ];
```

## Security notes

- **Bundled MariaDB root has no password.** The entrypoint leaves the `root`
  account on `unix_socket` auth (plus an empty password), and syncserver talks
  to the DB as root. mariadbd is started with `--bind-address=127.0.0.1`, so the
  database is reachable only on host loopback — but under `--network=host` that
  loopback is the *host's*, so any local process on the host can reach
  `127.0.0.1:3306`, and you must not open port 3306 in the host firewall. The DB
  holds only your own sync blobs (encrypted client-side by Firefox), but treat
  the host as the trust boundary.
- **The entrypoint is world-readable.** It is emitted via `writeShellScript`, so
  it lives in `/nix/store` readable by every local user. Keep real secrets out
  of it; the only sensitive value (`SYNC_MASTER_SECRET`) is passed separately via
  `secretsFile` and never baked into the image.

## Caveats

- **Single instance.** MariaDB lives inside the container with its datadir on a
  host bind-mount; run exactly one instance against a given `mariadbDataDir`.
- **Backups.** Everything durable is under `dataDir` / `mariadbDataDir`. Back those
  up (or snapshot them) — the container itself is disposable.
- **First boot is slower.** `mysql_install_db` runs once on an empty datadir; give
  the first start extra time before the ping loop’s 30s budget matters.
