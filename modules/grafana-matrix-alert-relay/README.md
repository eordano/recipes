# grafana-matrix-alert-relay

A small, single-file NixOS module that forwards Grafana alerts into a Matrix room, with
no bridge, no bot framework, and no third-party dependency — just Python
stdlib on loopback.

## The problem

Grafana's webhook contact point speaks one dialect: it **POSTs** a JSON
payload to a URL. The Matrix send API speaks another:

```
PUT /_matrix/client/v3/rooms/{roomId}/send/m.room.message/{txnId}
```

It requires `PUT` (not `POST`) **and** a caller-supplied transaction id in the
path. Grafana can produce neither. So you can't point Grafana straight at
Matrix — the verb is wrong and the txn id is missing.

## The fix

Run a minimal relay on `127.0.0.1`. Grafana POSTs alerts to it; the relay
re-shapes each alert into a well-formed Matrix `PUT` and sends it with a
bearer token.

## The insight worth stealing: deterministic transaction ids

Matrix's txn id exists specifically for idempotency — resend the same
`PUT .../send/m.room.message/{txn}` and the server treats it as the *same*
message rather than a new one. Most relays throw a random UUID at it, which
defeats the mechanism: every Grafana retry or duplicate delivery becomes
another line in the room.

This relay derives the txn id instead:

```
txn = f"grafana-{floor(now/300)}-{sha1(body)[:16]}"
```

The message body is hashed, and the current time is bucketed into 5-minute
windows. Identical alerts delivered or retried inside the same window reuse
the same txn id, so **the Matrix server dedupes them for you** — no local
state, no seen-cache, no cron cleanup. The 5-minute bucket bounds how long a
duplicate is suppressed; a genuinely re-firing alert in a later window posts
again, as it should.

## Secret handling

The bearer token is delivered through systemd `LoadCredential`, materialised
into the per-unit credentials directory (`%d/matrix-token`) at `0400`, owned by
the `DynamicUser`. It is **never** placed in the unit environment or on the
command line, so it doesn't leak into `systemctl show`, `/proc/<pid>/environ`,
or the journal. You supply the token file with whatever secret manager you use
(agenix, sops-nix, a deploy step); the module only needs a path.

## Usage

```nix
{
  imports = [ ./grafana-matrix-alert-relay ];

  services.grafana-matrix-alert-relay = {
    enable = true;
    matrixBase = "https://matrix.example.com";
    room = "!aBcDeFgHiJkLmNoPqR:example.com"; # internal room id, not the #alias
    tokenFile = "/run/secrets/matrix-alert-token";
    # port = 9099; # default
  };
}
```

Then add a Grafana **webhook** contact point pointing at
`http://127.0.0.1:9099/alert` (any path works) and a notification policy that
routes the alerts you care about to it. Example provisioning:

```yaml
# grafana contact point
apiVersion: 1
contactPoints:
  - orgId: 1
    name: matrix
    receivers:
      - uid: matrix-relay
        type: webhook
        settings:
          url: http://127.0.0.1:9099/alert
          httpMethod: POST
```

## Options

| Option        | Type   | Default | Notes |
|---------------|--------|---------|-------|
| `enable`      | bool   | `false` | |
| `port`        | port   | `9099`  | Loopback port the relay listens on. |
| `matrixBase`  | str    | —       | Homeserver client-server API base URL. |
| `room`        | str    | —       | Internal room id (`!...`), **not** the `#alias`. The bot must be joined. |
| `tokenFile`   | path   | —       | File with the raw bearer token; loaded via `LoadCredential`. |

## Getting the token and room id

- **Token**: log in as the bot account once and grab its access token (e.g.
  via `POST /_matrix/client/v3/login`, or from an Element session's
  *Help & About*). Treat it like a password.
- **Room id**: the internal id starts with `!` and is stable; the `#name:server`
  alias is just a pointer. In Element it's under *Room settings → Advanced →
  Internal room ID*. The bot account must be a member of the room before the
  relay can post.

## Message format

Alerts render as one line each:

```
[FIRING] HighCPU host=web-01: CPU above 90% for 5m
```

Status maps to a `[FIRING]` / `[RESOLVED]` / `[PENDING]` prefix; the summary is
taken from `annotations.summary`, falling back to `annotations.description`
then the alert name, and truncated at 400 chars. Adjust `format_alert` in
`default.nix` if you want HTML formatting (`m.room.message` also accepts
`format: org.matrix.custom.html` with a `formatted_body`).

## Caveats

- **Loopback only.** The relay binds `127.0.0.1`. Run it on the same host as
  Grafana. It does no auth on the inbound side — anything that can reach the
  port can post to your room, so don't expose it.
- **Egress is open.** The unit hardening (`DynamicUser`, `ProtectSystem`,
  `RestrictNamespaces`, ...) is tight, but `IPAddressAllow` permits all
  outbound because the relay needs DNS plus the homeserver. The token-gated
  room is the real boundary. Front it with an egress proxy if you need
  per-hostname control.
- **Fire-and-forget.** A failed Matrix POST is logged to stderr and dropped;
  there's no retry queue. For alerting this is usually fine (the next
  evaluation re-notifies), but it is not a guaranteed-delivery pipe.
- **One room.** Multi-room / severity-based routing would mean running more
  than one instance (they can share a port only if you change it), or teaching
  `format_alert`/`post_matrix` to pick a room from labels.
