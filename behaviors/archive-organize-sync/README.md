# archive-organize-sync

A timer-driven NixOS behavior that keeps a growing local archive tidy and
backed up, then reclaims local disk — **without ever risking a file that hasn't
been safely copied first**.

Each run does three things, in this order:

1. **Organize** — sort loose files in the archive's subdirectories into
   `YYYY.MM` month folders, keyed on each file's modification time.
2. **Sync** — additively `rsync` the archive to a remote/backup directory. The
   remote is the durable side; nothing is deleted there.
3. **Prune** — delete local files older than *N* days to free space.

## The trap this recipe encodes

The ordering is the whole point, and step 3 has a safety gate that is easy to
get wrong.

**A local file is deleted only after its remote copy is proven byte-identical
by sha256.** Not "rsync exited 0", not "the path exists on the remote" — an
actual content hash comparison per file:

```
sha256(local) == sha256(remote)  →  rm local
```

If a sync is interrupted, the remote is on a different filesystem that dropped
the write, or a file changed between sync and prune, the hashes won't match and
the local copy stays. Pruning can therefore never outrun a successful backup.
This is why the sequence must be organize → sync → **verify** → prune, and why
prune must re-hash rather than trust the sync's exit status.

## The second trap: yt-dlp sidecars

Tools like `yt-dlp` write a media file plus sidecars that share a filename stem
but have **different mtimes** — `video.mp4`, `video.info.json`,
`video.en.srt`, `video.webp`. Sorting each file independently by its own mtime
scatters a video's metadata across different month folders.

The `ytdlp` mode fixes this: it anchors each group on the `.info.json`, finds
the group's media file (the largest same-stem member), and moves the **whole
group** into the *media* file's month. The `.info.json` lands next to its
video. If the media is missing (download failed, json only), it falls back to
the json's own date.

## Usage

```nix
{
  imports = [ ./archive-organize-sync ];

  services.archiveOrganizeSync = {
    enable = true;
    user = "alice";                       # owner of localPath
    localPath = "/home/alice/archive";
    remotePath = "/mnt/backup/archive";   # a locally-mounted path
    retentionDays = 14;

    folders = [
      { name = "downloads";   mode = "organize"; }   # sort + sync + prune
      { name = "screenshots"; mode = "organize"; }
      { name = "photos";      mode = "sync-only"; }   # back up, never delete
      { name = "videos";      mode = "ytdlp"; }       # sort keeping sidecars grouped
    ];

    defaultMode = "sync-prune";           # any subdir not listed above
    interval = "daily";
  };
}
```

The module is self-contained — it ships both helper scripts (`archive-sync-start`
and `organize-yyyy-mm`) inline, so importing this one directory is enough.

## Options

| Option          | Default                | Meaning                                                              |
| --------------- | ---------------------- | ------------------------------------------------------------------- |
| `enable`        | `false`                | Turn the timer + oneshot on.                                        |
| `user`          | `"archive"`            | User the oneshot runs as; set to the owner of `localPath`.          |
| `localPath`     | `/var/lib/archive`     | Archive root; its **immediate subdirectories** are processed.       |
| `remotePath`    | `/mnt/backup/archive`  | rsync destination (see caveat below).                               |
| `retentionDays` | `14`                   | Prune local files older than this — only if the remote copy hashes equal. |
| `folders`       | `[ ]`                  | Per-subdirectory rules (`name` + `mode`).                           |
| `defaultMode`   | `"sync-prune"`         | Mode for any subdirectory not named in `folders`.                   |
| `interval`      | `"daily"`              | `systemd` `OnCalendar` expression.                                  |

### Modes

| Mode         | Organize into `YYYY.MM` | Sync to remote | Verified prune |
| ------------ | ----------------------- | -------------- | -------------- |
| `organize`   | yes                     | yes            | yes            |
| `ytdlp`      | yes (sidecars grouped)  | yes            | yes            |
| `ytdlp-only` | yes (sidecars grouped)  | yes            | **no**         |
| `sync-only`  | no                      | yes            | **no**         |
| `sync-prune` | no                      | yes            | yes            |

Use `sync-only` (or `ytdlp-only`, which still sorts) for anything you never
want auto-deleted locally (photo libraries, VM images, a media library the
remote is a backup of rather than an offload target), and
`organize`/`ytdlp`/`sync-prune` for churn you're happy to offload to backup
after a couple of weeks.

## Keep-list: pinning files that must not be sorted

`organize-yyyy-mm` reads an optional `.organize-yyyy-mm.config` in the directory
it's organizing — one filename per line, `#` comments allowed. Listed names (and
the config file itself) are never moved into a month folder. Handy for a README,
an index, or a working file that lives at the directory root.

## Caveats

- **`remotePath` is a plain filesystem path.** The verified-prune gate re-reads
  and hashes the remote file, so the remote must be a locally reachable path.
  For an off-host backup, mount it first (NFS, sshfs, an rclone mount, a
  bind-mounted block device) and point `remotePath` at the mountpoint. If the
  mount is absent at run time, rsync recreates the directory locally and files
  will *not* hash-match a real backup — verify your mount is up (e.g. order the
  service `after` the mount unit, or have the script bail if a sentinel file on
  the mount is missing).
- **mtime is the sort key.** Files whose mtime doesn't reflect their real date
  (restored-from-backup, `cp` without `-p`, unzipped archives) sort into the
  wrong month. Preserve timestamps when moving things into the archive.
- Month folders already matching `YYYY.MM` are left alone, so re-runs are
  idempotent and safe to run on a tight timer.
- The prune walk is per-file `sha256sum` on both sides; on very large archives
  that's I/O the run pays every cycle. Tune `retentionDays` and `interval`
  accordingly.
