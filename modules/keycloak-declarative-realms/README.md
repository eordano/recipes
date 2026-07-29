# keycloak-declarative-realms

A NixOS module that wraps the upstream `services.keycloak` and **provisions
realms, OIDC clients, and users through the admin REST API on first boot** — so a
whole Keycloak identity setup lives in your Nix config instead of being clicked
into the admin UI by hand.

## The problem

Keycloak has no first-class declarative-config surface for realms/clients/users
that fits cleanly into a NixOS deployment. You bring the server up, then someone
logs into the admin console and creates everything manually — which is exactly
the state you *don't* want tracked outside of your configuration. This module
closes that gap with a `keycloak-configure` oneshot that logs in as the admin,
waits for the API to be ready, and creates each object idempotently.

## The two traps this solves

### 1. The admin password must land in an EnvironmentFile *before* the service, and a `preStart` hook is too late

Keycloak reads its initial admin credentials from `KEYCLOAK_ADMIN` /
`KEYCLOAK_ADMIN_PASSWORD` environment variables. To keep the password out of the
Nix store and off the unit, we feed it via `EnvironmentFile=/run/keycloak/admin-env`.

The non-obvious part: **systemd resolves `EnvironmentFile` before it runs
`ExecStartPre`**. So you cannot write that file from a `preStart` script on
`keycloak.service` — by the time the script runs, systemd has already tried (and
failed) to read the file. The fix is a *separate* oneshot,
`keycloak-admin-setup.service`, ordered `before = [ "keycloak.service" ]`, that
reads `initialAdminPasswordFile` and writes a `0600 keycloak:keycloak` env file.
`keycloak.service` `requires` + `after` it. The password never enters the store
or the unit text.

That oneshot runs as `User = "keycloak"`, not root. `RuntimeDirectory =
"keycloak"` creates `/run/keycloak` already owned by that user (no manual
`mkdir`/`chown` needed), and the password itself is read through
`LoadCredential = "admin-password:${initialAdminPasswordFile}"` — systemd's PID1
(still root at that point) reads the source file on the unit's behalf and hands
it over via `$CREDENTIALS_DIRECTORY`, so the fix works regardless of whether
`initialAdminPasswordFile` is readable by anyone but root. Nothing in this unit
needs elevated privilege.

### 2. The configure script must talk to `http://localhost` — not the public hostname

The server runs plain HTTP (`http-enabled = true`, `hostname-strict{,-https} =
false`); TLS is a fronting reverse-proxy's job. But Keycloak's built-in `master`
realm defaults to `sslRequired = external`, which **rejects non-HTTPS requests
coming from any non-local address**. The reconciliation script therefore hits
`http://localhost:<port>` explicitly — a loopback address is exempt from the SSL
requirement, so admin login over plain HTTP works only from the box itself.

## Usage

Import the module and enable it:

```nix
{
  imports = [ ./modules/keycloak-declarative-realms ];

  services.keycloak-declarative = {
    enable = true;
    hostname = "auth.example.com";       # canonical URL (proxy terminates TLS)
    port = 8080;                          # plain-HTTP listen port
    bindAddress = "127.0.0.1";            # only the local proxy needs to reach it

    initialAdminPasswordFile = "/run/secrets/keycloak-admin-password";

    # Local PostgreSQL is provisioned by default over the unix socket (peer auth).
    # database.passwordFile is required regardless — see Caveats.
    database.passwordFile = "/run/secrets/keycloak-db-password";

    realms.myorg = {
      displayName = "My Organization";

      clients.my-app = {
        redirectUris = [ "https://app.example.com/oauth/callback" ];
        secretFile = "/run/secrets/oauth-client-secret";   # else a random one is generated
      };

      users.alice = {
        email = "alice@example.com";
        firstName = "Alice";
        lastName = "Example";
        passwordFile = "/run/secrets/alice-password";
      };
    };
  };
}
```

All secrets are passed as **paths to files** (`*File` options) so nothing
sensitive is interpolated into the Nix store. Point them at whatever secret
manager you use (agenix, sops-nix, `/run/secrets`, …).

### Key options

| Option | Default | Purpose |
| --- | --- | --- |
| `hostname` | `localhost` | Canonical hostname / URL for the server |
| `port` | `8080` | Plain-HTTP listen port |
| `bindAddress` | `127.0.0.1` | Interface to bind (`0.0.0.0` for all) |
| `openFirewall` | `false` | Open `port` in the firewall (only with TLS in front) |
| `adminUser` | `admin` | Bootstrap admin username |
| `initialAdminPasswordFile` | *(required)* | File holding the initial admin password |
| `database.type` | `postgresql` | Enum of one (see Caveats) |
| `database.createLocally` | `true` | Provision a local PostgreSQL DB + role |
| `database.useSocket` | `true` | Unix-socket peer auth vs. TCP `scram-sha-256` |
| `database.host` | `/run/postgresql` | Socket dir, or a host/IP for TCP (asserted to be the socket dir when `useSocket`) |
| `database.port` | `5432` | Ignored on the socket path |
| `database.name` | `keycloak` | Database name |
| `database.user` | `keycloak` | Database role |
| `database.passwordFile` | `null` | DB password file (always required — see Caveats) |
| `realms.<name>.displayName` | *(required)* | Human-readable realm name |
| `realms.<name>.clients.<id>` | `{}` | OIDC clients (`redirectUris`, `secretFile`) |
| `realms.<name>.users.<name>` | `{}` | Users (`email`, `firstName`, `lastName`, `passwordFile`) |
| `configurationAttempts` | `60` | Readiness-poll attempts before giving up |
| `configurationRetryDelay` | `2` | Seconds between poll attempts |

## Caveats

- **`database.passwordFile` is always required**, even on the default
  socket/peer-auth path where Keycloak connects as its own OS user and never
  actually uses a network password. The upstream `services.keycloak` module
  insists on one; the assertion here exists purely "for NixOS keycloak module
  compatibility."

- **Reconciliation is create-or-skip for clients and users.** Only realms are
  updated in place, and only their `displayName` (via GET-modify-PUT so other
  realm settings are preserved). Changing a client's `redirectUris`/`secretFile`
  or a user's password *after first creation* will **not** be picked up by a
  redeploy — edit it in the admin UI, or delete the object to force recreation on
  the next run.

- **A client with no `secretFile` gets an `openssl rand` secret echoed into the
  `keycloak-configure` journal** (once, at creation time). Prefer `secretFile`
  for any client whose secret is referenced elsewhere.

- **Provisioned users get permanent passwords** (`temporary: false`) and verified
  emails, so they log in immediately with no reset prompt. Adjust if you want a
  forced first-login reset.

- **The `keycloak-configure` oneshot runs as `nobody:nogroup`** yet `cat`s
  `initialAdminPasswordFile` (and every `passwordFile`/`secretFile`) directly. If
  your secret manager writes those files `0400 root:root` (the agenix/sops
  default), the unprivileged reconciler cannot read them and configuration fails.
  Fix this by granting *group* read to a group the reconciler is in — e.g. give
  the secret files mode `0040` and a shared owning group, then run the reconciler
  under a dedicated user in that group (override the unit's `User`/`Group`). Do
  **not** make the Keycloak admin password or client/user secrets world-readable:
  on a multi-user box any local account could then read them and take over every
  realm. World-readable is a last resort only, and never for the admin password.

- **Plain HTTP — front it with TLS.** The listener (admin console + admin-cli
  password-grant token endpoint) is cleartext HTTP. Keep `bindAddress =
  "127.0.0.1"` and put a TLS-terminating reverse proxy in front; the firewall
  port stays closed unless you set `openFirewall = true`. Binding to a
  non-loopback address and opening the port without a TLS proxy exposes admin
  credentials to LAN sniffing/brute-force — a full-realm compromise vector.

- **PostgreSQL only.** `database.type` is currently an enum of one.

- **Legacy bootstrap env vars.** Admin bootstrap here uses `KEYCLOAK_ADMIN` /
  `KEYCLOAK_ADMIN_PASSWORD`. Keycloak 26.0 renamed those to
  `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD` and kept the old
  names as deprecated aliases — nixpkgs' own `services.keycloak` already sets the
  new ones (for its `initialAdminPassword` path, which this module does not use).
  If your pinned Keycloak ever drops the deprecated aliases, change the
  `environment` key and the env-file key written by `keycloak-admin-setup`.

- **Port below 1024 needs a loopback bind.** An assertion rejects `port < 1024`
  unless `bindAddress = "127.0.0.1"` ("Ports below 1024 require root privileges.
  Use a higher port or bind to localhost only").

## How it works (internals worth knowing)

- The `keycloak-configure` oneshot runs as `nobody:nogroup` with a 5-minute
  `TimeoutStartSec`, after `keycloak.service` and `postgresql.service`.
- It polls `/realms/master` until the API answers valid JSON, then obtains an
  admin token via the `admin-cli` client (password grant).
- It calls `refresh_token` before *each* client and user to dodge token expiry on
  large configs.
- Client JSON is assembled with `lib.escapeShellArg` and the secret merged in via
  `jq --arg` (never string interpolation) to avoid shell-quoting hazards with
  arbitrary secret contents.
