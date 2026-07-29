# spool-dir-credential-broker

Keep a bearer token out of unprivileged sandboxes. Producers only drop JSON
manifests into a shared, sticky spool directory; one small hardened watcher
holds the credential and is the **sole** process that forwards those manifests
to an upstream REST API.

## The problem

You have a bunch of unprivileged, possibly sandboxed processes (CI jobs,
per-user agent sessions, ephemeral containers) that each need to register
something with a central API — say, announce a session so it can be routed to.
The API is authenticated with a bearer token.

The naive approach hands that token to every producer. Now the secret lives in
every sandbox: any one of them can read it, exfiltrate it, or call the API with
privileges far beyond "register my own session." And rotating it means touching
every producer.

## The design

Invert it. The producers never see the token. Instead:

```
unprivileged producers ──drop <id>.json──▶  spool dir (1777, sticky)
                                                  │  inotify
                                                  ▼
                                       broker unit (holds token)
                                                  │  Bearer <token>
                                                  ▼
                                          upstream REST API
```

1. **Producers** write a manifest `<id>.json` into a **sticky 1777** spool
   directory and delete it when done. That is their entire interface. They hold
   no credential and make no network calls.
2. **The broker** is one hardened systemd unit running as a dedicated user
   whose only privilege is *read access to the token*. It watches the spool
   with `inotify` and translates filesystem events into authenticated API
   calls:
   - a new/written `<id>.json` → `POST <createPath>` with the manifest body
   - a removed `<id>.json` → `DELETE <deletePath>/<id>`

The blast radius of a compromised producer is now "write a JSON file"; the
token lives in exactly one confined place.

## Key insights / traps

### The token is re-read on every request

The broker reads `tokenFile` fresh for each API call, not once at startup. So
when your secret manager rotates the token on disk, the very next forwarded
manifest uses the new value — **no restart, no reload**. This is the single
most important detail; a naive implementation that caches the token in a
variable would silently start failing after every rotation.

### The spool must be sticky (1777) — and this module does not create it

The whole security story depends on the spool being world-writable *with the
sticky bit*, so any local process can drop its own manifest but cannot delete
or overwrite another producer's. Provision it yourself, e.g.:

```nix
systemd.tmpfiles.rules = [
  "d /var/lib/spool-broker/inbox 1777 root root -"
];
```

The broker unit orders itself `after = [ "systemd-tmpfiles-setup.service" ]`
so the directory exists before it starts.

### The delete id comes from the filename, not the file

On delete the manifest content is already gone, so the resource id is recovered
from the filename stem (`<id>.json` → `<id>`). Producers **must** name the file
after the same id they put in the `idField` of the JSON, or teardown will
target the wrong resource. Create and delete are deliberately keyed the same
way.

### Startup reconciliation

Before it starts watching, the broker sweeps every `*.json` already in the
spool and re-forwards it. This means a broker restart re-announces manifests
that were dropped while it was down, instead of losing them. It also means your
upstream `POST` handler should be idempotent for an id that already exists.

### inotify events cover both write styles

It listens for `close_write` **and** `moved_to`: `close_write` catches
producers that write in place, `moved_to` catches the safer write-to-temp-then-
`rename(2)` pattern (which never exposes a half-written manifest). `delete` and
`moved_from` both trigger teardown. Dotfiles and non-`.json` names are ignored.

### Hardening

The unit runs with `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`,
`NoNewPrivileges`, the token mounted `ReadOnlyPaths` and the spool the only
`ReadWritePaths`. The point: this process holds the one real credential in the
system, so it should be able to touch nothing else. Run it as a dedicated
low-privilege user.

The bearer token is **never** placed on curl's command line. Process arguments
are readable via `/proc/<pid>/cmdline` by every local user on a stock host, so a
token passed as `-H "Authorization: Bearer …"` would be scrapable by the very
unprivileged producers this module is meant to confine. Instead the
`Authorization` header is piped to curl as a config on stdin (`curl -K -`), so
the secret never shows up in the process arguments. If you adapt the `api`
function for a different upstream, keep the token off argv the same way.

## Usage

```nix
{
  imports = [ ./spool-dir-credential-broker ];

  # You create the sticky spool dir:
  systemd.tmpfiles.rules = [
    "d /var/lib/spool-broker/inbox 1777 root root -"
  ];

  users.users.spool-broker = {
    isSystemUser = true;
    group = "spool-broker";
  };
  users.groups.spool-broker = { };

  services.spoolCredentialBroker = {
    enable = true;
    spoolDir = "/var/lib/spool-broker/inbox";
    tokenFile = "/run/secrets/upstream-token"; # readable by the user below
    upstreamUrl = "https://api.example.com";
    user = "spool-broker";
    # optional, defaults shown:
    # createPath = "/api/sessions";
    # deletePath = "/api/sessions";
    # idField    = "slug";
  };
}
```

A producer registers itself by writing (atomically, ideally):

```sh
tmp=$(mktemp)
printf '{"slug":"job-42","cmd":"..."}' > "$tmp"
mv "$tmp" /var/lib/spool-broker/inbox/job-42.json
```

and unregisters by removing `job-42.json`.

## Options

| Option        | Default                       | Meaning                                             |
| ------------- | ----------------------------- | --------------------------------------------------- |
| `enable`      | `false`                       | Turn the broker on.                                 |
| `spoolDir`    | `/var/lib/spool-broker/inbox` | Sticky dir producers drop manifests into (create it yourself). |
| `tokenFile`   | *(required)*                  | File holding the bearer token; readable only by `user`. |
| `upstreamUrl` | *(required)*                  | Base URL of the upstream REST API.                  |
| `createPath`  | `/api/sessions`               | Path POSTed to with the manifest body on create.    |
| `deletePath`  | `/api/sessions`               | Base path DELETEd as `<deletePath>/<id>` on remove. |
| `idField`     | `slug`                        | JSON field carrying the id (also the filename stem).|
| `user`        | *(required)*                  | Dedicated user the broker runs as.                  |
| `group`       | `= user`                      | Group the broker runs as.                           |

## Caveats

- The upstream contract here is a simple `POST create` / `DELETE by id` REST
  shape with the id in a JSON field. If your API differs (different verbs, id in
  the URL for create, envelope format), adapt the `api`/`handle_*` shell
  functions — the pattern (spool → confined watcher → authenticated forward) is
  what's reusable, not the exact endpoints.
- There is no backpressure or retry queue: a manifest that fails to forward is
  logged and dropped until the next inotify event or restart. If you need
  at-least-once delivery, add a retry/spool-of-failures on top.
- Producers can spoof each other's ids (they share the dir). The sticky bit
  stops them deleting each other's *files*, but not writing a manifest claiming
  someone else's id. Trust boundary is "local processes"; if that's too broad,
  give each producer its own drop dir.
