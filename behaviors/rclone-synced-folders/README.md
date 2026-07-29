# rclone-synced-folders

A NixOS module for declarative folder sync between a host and a remote over
SFTP, using [rclone](https://rclone.org). Two modes, one config:

- **lazy** — the remote is mounted as a FUSE VFS with a local on-disk cache
  (`systemd.mounts` + `systemd.automounts`). Files are fetched on demand and
  cached locally; nothing is copied up front. Great for large trees you only
  touch part of (repo collections, media, archives).

- **full** — `rclone bisync` on a timer. Bidirectional, newest file wins,
  deletions propagate. Good for smaller working sets you edit on both ends
  (documents, notes).

## The problem it solves

You want a folder to exist on two machines without running a heavyweight sync
daemon, without a cloud provider, and using nothing but an SSH key you already
have. rclone-over-SFTP gives you exactly that — but naive bidirectional sync is
a footgun, and mounting over the network has its own sharp edges. This module
packages the safe version of both.

## The traps this module defends against

`rclone bisync` is genuinely dangerous the first time and whenever a side goes
missing. The module bakes in the guardrails that make it survivable:

1. **The `--resync` baseline runs exactly once.** bisync needs an initial
   `--resync` to establish its "last known good" state — and `--resync` is
   *destructive*: it picks a winner and overwrites the other side. If it ran on
   every boot it would clobber real edits. The module records success in a
   per-folder `/var/lib/synced-folders/<name>.resync-done` state file and only
   ever runs the plain (safe) bisync afterward.

2. **RCLONE_TEST + `--check-access` refuse to sync into an empty/broken side.**
   The classic disaster: your local mount didn't come up, so the folder looks
   *empty*, and a bidirectional sync happily mirrors that emptiness to the
   remote — deleting everything. The module drops an `RCLONE_TEST` sentinel file
   on both ends and passes `--check-access`, so bisync aborts loudly if either
   sentinel is missing instead of propagating the emptiness.

3. **`maxDelete` aborts a run that would delete too much.** A percentage ceiling
   (`--max-delete`, default 50%) is a last-resort circuit breaker: if something
   still goes wrong and a run would delete more than that fraction of files,
   rclone bails instead of finishing the job.

4. **A `flock` lock serialises runs** so a slow sync and the next timer tick
   can't stomp on each other.

For the lazy/FUSE mode the subtle bit is the numeric identity: rclone's mount
wants a numeric `uid`/`gid`, not a username. The module derives them from the
declared `owner`/`ownerGroup` (or you set them explicitly) so the mounted files
are owned by a real user rather than root.

## Usage

```nix
{
  imports = [ ./rclone-synced-folders ];

  services.synced-folders = [
    # Lazy VFS mount: big repo tree, fetched on demand.
    {
      name       = "repos";
      server     = "your-host";                 # any SSH-reachable host or IP
      user       = "alice";                     # SFTP user on the remote
      sshKeyFile = "/home/alice/.ssh/id_ed25519";
      serverPath = "/home/alice/repos";
      localPath  = "/home/alice/repos";
      owner      = "alice";
      type       = "lazy";
      cacheDir   = "/var/cache/rclone-repos";   # required for lazy
    }

    # Full bisync on a timer: documents edited on both machines.
    {
      name       = "documents";
      server     = "your-host";
      user       = "alice";
      sshKeyFile = "/home/alice/.ssh/id_ed25519";
      serverPath = "/home/alice/documents";
      localPath  = "/home/alice/documents";
      owner      = "alice";
      type       = "full";
      syncInterval = "5min";
    }
  ];
}
```

## Options (per folder)

| Option | Applies to | Default | Meaning |
| --- | --- | --- | --- |
| `name` | both | — | Unique id, used in systemd unit names. |
| `server` | both | — | SSH-reachable hostname/IP of the remote. |
| `port` | both | `22` | SSH port. |
| `user` | both | — | SFTP username on the remote. |
| `sshKeyFile` | both | — | Path to the private key for auth. |
| `serverPath` | both | — | Path on the remote. |
| `localPath` | both | — | Local mount/sync path. |
| `owner` / `ownerGroup` | both | — / `users` | Local owner of the files. |
| `type` | both | `lazy` | `lazy` (VFS mount) or `full` (bisync). |
| `cacheDir` | lazy | `null` | VFS cache dir (**required** for lazy). |
| `uid` / `gid` | lazy | derived | Numeric ids for the mount; derived from `owner`/`ownerGroup` when null. |
| `cacheMaxAge` / `cacheMaxSize` | lazy | `2160h` / `100G` | LRU eviction bounds. |
| `dirCacheTime`, `pollInterval`, `vfsCachePollInterval`, `logLevel` | lazy | see module | VFS tuning. |
| `syncInterval` | full | `15min` | Timer interval. |
| `syncOnBoot` | full | `true` | Also run shortly after boot. |
| `excludePatterns` | full | git/venv/cache junk | rclone filter excludes. |
| `maxDelete` | full | `50` | Abort if >N% of files would be deleted. |
| `afterUnits` | both | `[ "network-online.target" ]` | systemd `After=` ordering. |

## Caveats

- **Network reachability.** By default the mount/sync only orders after
  `network-online.target`. If the remote is only reachable over a VPN/overlay
  (Tailscale, WireGuard, …), add that unit to `afterUnits`, e.g.
  `afterUnits = [ "network-online.target" "tailscaled.service" ]`, so the mount
  waits for the tunnel instead of racing it.

- **uid/gid derivation.** For `lazy` folders the module derives numeric ids from
  the NixOS-declared `owner` user / `ownerGroup`. If the owner isn't a declared
  NixOS user, set `uid`/`gid` explicitly — an assertion will tell you if it
  can't resolve them.

- **First `full` run is a baseline, not a merge.** The initial `--resync` picks
  a winner side; make sure the side you consider authoritative is populated
  before enabling a new `full` folder. After that first run the state file keeps
  it from ever re-baselining.

- **Sync services run as root** (so they can `chown` the target). The SSH key in
  `sshKeyFile` must be readable in that context.

- **Lazy mode relaxes FUSE host-wide.** Because the VFS mount is created by root
  (via `systemd.mounts`) but should be usable by the `owner` user, lazy folders
  mount with `allow_other` and set `programs.fuse.userAllowOther = true`, which
  writes `user_allow_other` into the machine-wide `/etc/fuse.conf`. On a
  multi-user host this means (a) files in the mount that are group/other-readable
  become reachable by any local user, subject to their normal permissions, and
  (b) any local user may henceforth pass `allow_other` on FUSE mounts they create
  themselves. This is a no-op concern on a single-user machine; on a shared host,
  keep the synced tree's own permissions tight and be aware of the relaxation.

- Logs land in `/var/log/rclone-<name>.log` (lazy) and
  `/var/log/synced-folders-<name>.log` (full); bisync state lives under
  `/var/lib/synced-folders/`.

## Requirements

`pkgs.rclone` (pulled in automatically) with SFTP support — standard in nixpkgs.
The `rclone` mount type for `systemd.mounts` is provided by rclone's
`mount.rclone` helper, which the package ships.
