# forgejo-declarative-admin-user

A NixOS module that **declaratively creates and keeps in sync a Forgejo admin
user** — the kind you need for automated, unattended auth (API scripts, repo
mirroring/bisync, CI). A post-startup systemd oneshot ensures the user exists and
that its password matches a secret file, so the account lives in your Nix config
instead of being clicked into the admin UI once and then forgotten.

## The problem

Any automated client that talks to Forgejo over HTTP Basic auth needs a real user
with a known password. Creating that user by hand is fine exactly once — but then
the password is untracked, rotating it is a manual chore, and rebuilding the host
loses the account entirely. You want the user and its current password to be a
*declared desired state* that a redeploy (or a secret rotation) reconciles.

## How it works

On boot the module runs a oneshot that:

1. Waits for Forgejo to answer a readiness probe (`readyUrl`, optionally over a
   unix socket).
2. Runs `forgejo admin user create --admin … || true`. The `|| true` is
   deliberate: Forgejo errors out if the user already exists, and that's not a
   failure we care about — creation is best-effort.
3. Runs `forgejo admin user change-password …`. **This is the real
   desired-state enforcer.** It runs every time, so it also handles password
   rotation.

The systemd unit lists `passwordFile` in `restartTriggers`, so when that *value*
changes the unit re-runs and pushes the new password into Forgejo. Mind what
"changes" means: `X-Restart-Triggers` records the trigger's text, so it only fires
when the path itself differs between generations. A secret manager that hands you
a stable runtime path (`/run/secrets/…`, `/run/agenix/…`) rotates the file's
*contents* behind an unchanged path, and the unit will **not** notice.

**Rotating the secret is therefore a two-step operation: write the new secret,
then `systemctl restart forgejo-admin-user.service`.** The module could have
triggered on the file's *contents* instead — but only by reading the password at
evaluation time and hashing it into the unit, which puts the cleartext secret in
the world-readable Nix store. Keeping the secret out of the store is worth the
manual restart, and `change-password` is idempotent so re-running it is always
safe.

## The load-bearing trap: `--must-change-password`

`forgejo admin user change-password` (and `admin user create`) **default
`--must-change-password` to `true`**. That flag forces an interactive password
change on the account's next login. An unattended client cannot complete an
interactive password change — so **every automated API call from that user 403s**,
silently and forever.

The nasty part is that the user gets created *perfectly fine*; nothing looks
wrong until the automation starts failing with 403s that have no obvious cause.
You must pass `--must-change-password=false` explicitly on **both** the create and
the change-password calls. This module always does.

## Usage

```nix
{
  imports = [ ./modules/forgejo-declarative-admin-user ];

  services.forgejo-admin-user = {
    enable = true;

    username = "automation";
    email = "automation@example.com";
    passwordFile = "/run/secrets/forgejo-admin-password";

    # How to invoke the Forgejo CLI on this host (see below).
    forgejoCli = "${pkgs.forgejo}/bin/forgejo --config /var/lib/forgejo/custom/conf/app.ini";
    serviceUser = "forgejo";

    # Wait for Forgejo, then probe it for readiness.
    afterUnits = [ "forgejo.service" ];
    readyUrl = "http://127.0.0.1:3000/api/v1/version";
  };
}
```

### Adapting to your Forgejo's shape

The CLI has to run against the same config/data dir Forgejo uses, and the two
common deployment shapes need different wiring:

**Native `services.forgejo`** — call the binary directly, and run the oneshot as
the `forgejo` user so the CLI can read the data dir:

```nix
forgejoCli   = "${pkgs.forgejo}/bin/forgejo --config /var/lib/forgejo/custom/conf/app.ini";
serviceUser  = "forgejo";
```

If that host listens on a **unix socket** with no TCP port, point the readiness
probe at the socket:

```nix
readyUrl        = "http://localhost/api/v1/version";
readyUnixSocket = "/run/forgejo/forgejo.sock";
```

**Forgejo in a container** — exec into it, and run the oneshot as `root`:

```nix
forgejoCli   = "podman exec -i forgejo forgejo --config /data/custom/conf/app.ini";
serviceUser  = "root";
afterUnits   = [ "podman-forgejo.service" ];
readyUrl     = "http://127.0.0.1:3000/api/v1/version";
```

### Key options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the bootstrap oneshot on |
| `username` | `automation` | The admin user to create/maintain |
| `email` | *(required)* | Email for the user (Forgejo requires one) |
| `passwordFile` | *(required)* | File holding the password; also the `restartTriggers` source |
| `forgejoCli` | *(required)* | Shell prefix that runs the Forgejo CLI against this host's config |
| `serviceUser` | `root` | User the oneshot runs as (`forgejo` for native, `root` for container-exec) |
| `afterUnits` | `[ "network-online.target" ]` | Units to order after / wait for |
| `readyUrl` | *(required)* | URL that returns 2xx when Forgejo is ready |
| `readyUnixSocket` | `null` | Probe via this unix socket instead of TCP |
| `readyTimeoutSec` | `180` | How long to wait for readiness before aborting |

## Caveats

- **The password is passed as a *path* (`passwordFile`)**, read by the oneshot at
  run time, so it never lands in the Nix store or the unit text — provided you
  pass a runtime path *string*. A Nix path literal (`./admin-password`) would be
  copied into the world-readable store instead. Point it at any secret manager
  (agenix, sops-nix, `/run/secrets/…`).

- **Mirror both sides of a two-Forgejo setup.** If you use this to back a
  bidirectional mirror where one client auths to two Forgejo instances with one
  shared password, enable the module on *each* Forgejo host and point every copy
  at the same secret so `username` / `email` / password all match.

- **`create` is best-effort, `change-password` is authoritative.** If you rename
  the user (`username`), the old account is not deleted — the module only ever
  reconciles the account it's told about.

- **The unit runs `wantedBy = multi-user.target` with `Restart = on-failure`.**
  If Forgejo never becomes ready within `readyTimeoutSec`, the oneshot fails and
  retries rather than silently doing nothing — check its journal if the user
  isn't appearing.

## Security notes

- **The password is briefly visible in the process table.** The Forgejo CLI only
  accepts the password as a `--password <value>` argv flag, so for the duration of
  each `create` / `change-password` call the cleartext password is readable via
  `/proc/<pid>/cmdline` (or `ps auxww`) by any local user on the host. The secret
  still never touches the Nix store or the unit text, but on a *multi-user*
  Forgejo box treat the password as exposed to other local accounts during the
  short window the oneshot runs (at boot and on rotation).

- **`serviceUser` defaults to `root`.** That default exists for the container-exec
  shape (`podman exec …`, which needs root). The oneshot runs your adopter-supplied
  `forgejoCli` prefix plus the password read, so with the root default any bug in
  that command or a compromise of the referenced CLI/secret path executes as root.
  For a native `services.forgejo` host set `serviceUser = "forgejo"` (least
  privilege — the CLI only needs to read the data dir).
