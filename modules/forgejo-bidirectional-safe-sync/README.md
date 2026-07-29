# forgejo-bidirectional-safe-sync

A NixOS module that keeps **two Forgejo instances mirrored to each other** from a
neutral third box — so neither forge depends on the other for backup or HA.

Each timer tick, the sync engine walks every repo on both sides via the Forgejo
API and reconciles refs **symmetrically**:

- **fast-forward** a ref wherever it is safe (one side strictly ahead of the other),
- **propagate** brand-new repos and refs to the peer,
- and **alert** on genuine divergence (both sides moved, neither is an ancestor
  of the other) instead of force-pushing over either side.

## Why a third box?

If forge A backed up *to* forge B (or vice versa), losing one forge degrades the
other's recovery story, and the natural "just push" fix is a force-push waiting
to clobber real work. Running the reconciler on an independent host makes the
relationship peer-to-peer: when either forge is down, the survivor still holds a
complete copy, and the box quietly re-converges once the peer returns. This is
exactly the machinery you want during an unplanned outage of one forge.

## Safety guarantees

The reconciler is built to never destroy history. It:

- issues **no `--force` / `--force-with-lease` pushes** — a non-fast-forward push
  is refused by Forgejo and logged;
- **never deletes refs** — deleting a branch on one side does *not* propagate;
- **never deletes or renames repos** — a repo present on one side but missing on
  the other (after having been seen on both) is flagged as
  `rename-or-delete-suspected` and skipped, not re-created or removed;
- **never auto-creates owners** — if a new repo's owner doesn't exist on the
  target, it is skipped and alerted (optionally routed to a fallback org, see
  `unownedReposTarget`).

Worst-case failure mode: a stale ref on one side until the next cycle. True
conflicts surface as structured `diverged` / `alert-divergence` log events; a
human pushes a merge or rebase and the next cycle converges.

## The load-bearing trap: `EnvironmentFile = "-…"`

The service materializes its config (including the admin password) into a tmpfs
env file under `/run` via an `ExecStartPre`, then runs the sync engine with that
file as its `EnvironmentFile`. (Both steps run unprivileged — see the next
section.)

Because `/run` is tmpfs, **the env file does not exist on the first cycle after
boot**, and systemd loads `EnvironmentFile` *before* it runs `ExecStartPre` (the
step that creates it). If the path is listed **without** a leading `-`, the unit
dies with `Failed to load environment files` before the pre-step can ever run —
a permanent boot-time loop.

The fix is the single `-` optional-load prefix:

```nix
EnvironmentFile = "-/run/forgejo-bisync/env";
```

The first load no-ops, `ExecStartPre` writes the file, and `ExecStart` reads it.
Keep that dash.

## Nothing in this unit runs as root

`ExecStartPre` used to run with systemd's `+` prefix purely so it could read
`passwordFile` and own the tmpfs env file it writes. Neither actually needs
root: `RuntimeDirectory = cfg.user` already creates `/run/forgejo-bisync` owned
by the sync user (replacing a manual `install -d -o -g`), and
`LoadCredential = "password:${passwordFile}"` lets systemd's PID1 — still root
at that point — read the secret on the unit's behalf and hand it over via
`$CREDENTIALS_DIRECTORY`. That works no matter how restrictive `passwordFile`'s
own permissions are, so `ExecStartPre` and `ExecStart` both run as the
unprivileged `forgejo-bisync` user throughout, and an assertion rejects
`user = "root"` at build time.

## Usage

```nix
{
  imports = [ ./forgejo-bidirectional-safe-sync ];

  services.forgejo-bisync = {
    enable = true;

    # Your reconciliation engine (see "The sync engine" below).
    syncScript = ./sync.ts;

    instances = [
      { name = "forge-a"; baseUrl = "https://forge-a.example.com"; }
      { name = "forge-b"; baseUrl = "https://forge-b.example.com"; }
    ];

    # An admin account that exists with the SAME password on BOTH forges.
    username = "bisync";
    passwordFile = config.age.secrets.bisync-password.path; # or sops/systemd-creds/etc.

    interval = "5min";
    # excludeOwners = [ "mirrors" ];
    # unownedReposTarget = "archive"; # org on the target for owner-less repos
  };
}
```

Run this module on a host that is **neither** forge. You are responsible for
provisioning the `username` admin account (with `passwordFile`'s password) on
both Forgejo instances — a tiny declarative bootstrap per forge, or a manual
admin user, both work. The account needs admin scope so the API can enumerate
every repo and create repos on either side.

### Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the timer + sync service on. |
| `syncScript` | *(required)* | Path to the reconciliation engine. |
| `interpreter` | `node --experimental-strip-types` | Argv prefix to run the script; `null` to exec it directly. |
| `instances` | *(required)* | Exactly two `{ name; baseUrl; }` forges. `name` is the git remote name and log label. |
| `user` | `forgejo-bisync` | System user/group and `/run` subdir name. |
| `username` | `bisync` | Admin login present on both forges. |
| `passwordFile` | *(required)* | File with the shared admin password. |
| `interval` | `5min` | `OnUnitActiveSec` between cycles. |
| `workDir` | `/var/lib/forgejo-bisync` | Bare clones + `state.json`. |
| `parallelism` | `1` | Repos processed concurrently. |
| `alertOnDivergeAfterMs` | `1800000` | Grace period before a diverged ref escalates to `alert-divergence`. |
| `excludeRepos` | `[ ]` | `owner/name` strings to skip. |
| `excludeOwners` | `[ ]` | Whole owners (users/orgs) to skip. |
| `unownedReposTarget` | `null` | Fallback org on the target for repos whose owner is missing there; `null` = skip + alert. |

## The sync engine

The module is deliberately just the packaging (system user, secret plumbing,
hardened oneshot service, and timer). The reconciliation logic is an external
script you supply via `syncScript`. It receives **all** of its configuration
from environment variables in the tmpfs env file — no CLI args, no config file:

| Env var | From option |
| --- | --- |
| `BISYNC_USERNAME` | `username` |
| `BISYNC_PASSWORD` | contents of `passwordFile` |
| `BISYNC_A_NAME` / `BISYNC_A_BASE_URL` | `instances` element 0 |
| `BISYNC_B_NAME` / `BISYNC_B_BASE_URL` | `instances` element 1 |
| `BISYNC_WORK_DIR` | `workDir` |
| `BISYNC_STATE_FILE` | `${workDir}/state.json` |
| `BISYNC_PARALLELISM` | `parallelism` |
| `BISYNC_ALERT_DIVERGE_MS` | `alertOnDivergeAfterMs` |
| `BISYNC_EXCLUDE_REPOS` | comma-joined `excludeRepos` |
| `BISYNC_EXCLUDE_OWNERS` | comma-joined `excludeOwners` |
| `BISYNC_UNOWNED_TARGET` | `unownedReposTarget` (empty when null) |

A conformant engine, per cycle, does roughly:

1. **Discover** — `GET /api/v1/repos/search` on both instances (paginated) using
   HTTP Basic Auth with `username:password`. The admin account sees every repo.
2. **For each repo present on both sides**, fetch all heads and tags into a bare
   clone (one namespaced remote per instance), then per ref:
   - equal SHAs → nothing to do;
   - present on one side only → fast-forward push to the other;
   - both present, one is a strict ancestor of the other → fast-forward the
     behind side up to the ahead side;
   - both moved, neither an ancestor → **diverged**: log it, never force.
3. **For a repo present on one side only** — if never seen before, create it on
   the target (respecting `unownedReposTarget`) and seed every ref; if seen
   before, treat as a suspected rename/delete and skip.
4. **Persist** a small `state.json` (last-synced ref SHAs, `divergedSince`
   timestamps) so divergence can be aged before escalating to
   `alert-divergence`, and so a vanished repo can be distinguished from a
   brand-new one.

Emit one structured JSON log line per event (`synced`, `ff-pushed`, `created`,
`diverged`, `alert-divergence`, `skipped`, `error`) so a log pipeline can alert
on divergence.

### Git-over-HTTPS gotchas worth keeping

Two settings the reference engine sets on every fetch/push, learned from large
repos:

```
-c http.version=HTTP/1.1
-c http.postBuffer=1048576000
```

Multi-GB repositories fail over HTTP/2 with `curl 92 stream reset by server` /
early EOF; forcing HTTP/1.1 avoids the multiplexed-stream reset, and the large
`postBuffer` keeps big pushes from chunking into a server-rejected size.

Also: some Forgejo versions reject `sort=newest` on `/repos/search` with a
`422 Invalid sort mode` — omit the sort param, ordering is irrelevant when you
collect results into a map.

## Caveats

- **Exactly two** instances, with **distinct** `name` values (both asserted).
- The admin password is the same on both forges by design — it is the shared
  identity the reconciler authenticates as. Scope it to a dedicated bisync
  account, not a human admin.
- The service is a `oneshot` with `Restart=no`; transient network/API failures
  are expected and simply retried on the next timer tick.
- Runs hardened (`ProtectSystem=strict`, filtered syscalls, no new privileges);
  the only writable locations are `workDir` and the unit's own
  `RuntimeDirectory` under `/run` (where the env file is written, mode `0400`).
