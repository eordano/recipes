# rclone-synced-folders
#
# Declarative rclone-over-SFTP folder sync for NixOS, in two modes:
#
#   - lazy: the remote is mounted as a FUSE VFS with a local on-disk cache
#     (systemd.mounts + systemd.automounts). Files are fetched on demand and
#     cached; nothing is copied up front. Requires `cacheDir`.
#
#   - full: rclone bisync on a timer. Bidirectional, newer file wins, deletions
#     propagate. The first run auto-establishes a `--resync` baseline, tracked by
#     a per-folder `.resync-done` state file so the destructive baseline runs
#     exactly once. `--check-access` + RCLONE_TEST sentinels refuse to sync into
#     an empty/broken mount, and `maxDelete` aborts a run that would delete too
#     large a fraction of files.
#
# Both modes share one generated rclone config (one SFTP remote per folder).
#
# Usage:
#   imports = [ ./rclone-synced-folders ];
#   services.synced-folders = [
#     {
#       name       = "repos";
#       server     = "your-host";                # any SSH-reachable host
#       user       = "alice";
#       sshKeyFile = "/home/alice/.ssh/id_ed25519";
#       serverPath = "/home/alice/repos";
#       localPath  = "/home/alice/repos";
#       owner      = "alice";
#       type       = "lazy";
#       cacheDir   = "/var/cache/rclone-repos";
#     }
#     {
#       name       = "documents";
#       server     = "your-host";
#       user       = "alice";
#       sshKeyFile = "/home/alice/.ssh/id_ed25519";
#       serverPath = "/home/alice/documents";
#       localPath  = "/home/alice/documents";
#       owner      = "alice";
#       type       = "full";
#       syncInterval = "5min";
#     }
#   ];

{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.synced-folders;

  folderOpts =
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          description = "Unique identifier for this sync (used in systemd unit names).";
        };

        server = mkOption {
          type = types.str;
          example = "your-host";
          description = "Hostname or IP of the remote host reachable over SSH/SFTP.";
        };

        port = mkOption {
          type = types.int;
          default = 22;
          description = "SSH port on the remote host.";
        };

        serverPath = mkOption {
          type = types.str;
          example = "/home/alice/repos";
          description = "Path on the remote host to sync.";
        };

        localPath = mkOption {
          type = types.str;
          example = "/home/alice/repos";
          description = "Local path where the folder is mounted (lazy) or synced (full).";
        };

        type = mkOption {
          type = types.enum [
            "lazy"
            "full"
          ];
          default = "lazy";
          description = ''
            Sync type:
            - lazy: rclone VFS mount with a local cache, files fetched on demand.
            - full: rclone bisync, bidirectional, newest file wins, deletions propagate.
          '';
        };

        sshKeyFile = mkOption {
          type = types.str;
          example = "/home/alice/.ssh/id_ed25519";
          description = "Path to the private SSH key used to authenticate to the remote host.";
        };

        user = mkOption {
          type = types.str;
          example = "alice";
          description = "Username for the SSH/SFTP connection to the remote host.";
        };

        owner = mkOption {
          type = types.str;
          example = "alice";
          description = "Local user that owns the mounted/synced files.";
        };

        ownerGroup = mkOption {
          type = types.str;
          default = "users";
          description = "Local group that owns the mounted/synced files.";
        };

        uid = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = ''
            Numeric uid presented by the FUSE VFS mount (lazy only). rclone's mount
            option needs a number, not a name. Leave null to derive it from the
            declared `owner` user (config.users.users.<owner>.uid); set it explicitly
            when the owner is not a NixOS-declared user.
          '';
        };

        gid = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = ''
            Numeric gid presented by the FUSE VFS mount (lazy only). Leave null to
            derive it from the declared `ownerGroup` (config.users.groups.<group>.gid).
          '';
        };

        cacheDir = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "/var/cache/rclone-repos";
          description = "Directory for VFS cache storage (required for lazy type).";
        };

        cacheMaxAge = mkOption {
          type = types.str;
          default = "2160h";
          description = "Maximum age of cached files before LRU eviction (lazy only).";
        };

        cacheMaxSize = mkOption {
          type = types.str;
          default = "100G";
          description = "Maximum size of the VFS cache (lazy only).";
        };

        logLevel = mkOption {
          type = types.enum [
            "DEBUG"
            "INFO"
            "NOTICE"
            "ERROR"
          ];
          default = "INFO";
          description = "Log level for the rclone VFS mount (lazy only).";
        };

        dirCacheTime = mkOption {
          type = types.str;
          default = "5m";
          description = "How long to cache directory listings (lazy only).";
        };

        pollInterval = mkOption {
          type = types.str;
          default = "15s";
          description = "How often to poll the remote for changes (lazy only).";
        };

        vfsCachePollInterval = mkOption {
          type = types.str;
          default = "60s";
          description = "How often to poll cached files for changes (lazy only).";
        };

        syncInterval = mkOption {
          type = types.str;
          default = "15min";
          description = "How often to run the bidirectional sync (full only).";
        };

        syncOnBoot = mkOption {
          type = types.bool;
          default = true;
          description = "Run the sync shortly after boot (full only).";
        };

        excludePatterns = mkOption {
          type = types.listOf types.str;
          default = [
            ".git/objects/**"
            ".git/lfs/**"
            "node_modules/**"
            "__pycache__/**"
            ".venv/**"
            "*.pyc"
            ".DS_Store"
          ];
          description = "Patterns to exclude from sync (full only, rclone filter syntax).";
        };


        maxDelete = mkOption {
          type = types.int;
          default = 50;
          description = ''
            Safety limit: abort a sync run if more than this percentage of files
            would be deleted (full only). Guards against a broken/empty side
            wiping out the other.
          '';
        };

        afterUnits = mkOption {
          type = types.listOf types.str;
          default = [ "network-online.target" ];
          example = [
            "network-online.target"
            "tailscaled.service"
          ];
          description = ''
            systemd units the mount/sync should order After=. Defaults to plain
            network readiness. If the remote is only reachable over a VPN/overlay
            network (e.g. Tailscale, WireGuard), add that unit here so the mount
            waits for it.
          '';
        };
      };
    };

  sanitizeName = name: replaceStrings [ "/" ] [ "-" ] name;

  lazyFolders = filter (f: f.type == "lazy") cfg;
  fullFolders = filter (f: f.type == "full") cfg;

  # Resolve the numeric uid/gid for a lazy mount: explicit option wins, otherwise
  # derive from the host's declared owner user / owner group.
  resolveUid = f: if f.uid != null then f.uid else attrByPath [ "users" "users" f.owner "uid" ] null config;
  resolveGid = f: if f.gid != null then f.gid else attrByPath [ "users" "groups" f.ownerGroup "gid" ] null config;

  rcloneConfig = concatStringsSep "\n" (
    map (f: ''
      [${sanitizeName f.name}]
      type = sftp
      host = ${f.server}
      port = ${toString f.port}
      user = ${f.user}
      key_file = ${f.sshKeyFile}
      shell_type = unix
      md5sum_command = md5sum
      sha1sum_command = sha1sum
    '') cfg
  );

  mkFilterFile =
    f:
    pkgs.writeText "filter-${sanitizeName f.name}" (
      concatMapStringsSep "\n" (p: "- ${p}") f.excludePatterns
    );

  mkSyncScript =
    f:
    pkgs.writeShellScript "sync-${sanitizeName f.name}" ''
      set -euo pipefail

      LOCAL="${f.localPath}"
      REMOTE="${sanitizeName f.name}:${f.serverPath}"
      CONFIG="/etc/rclone/synced-folders.conf"
      FILTER_FILE="${mkFilterFile f}"
      STATE_DIR="/var/lib/synced-folders"
      STATE_FILE="$STATE_DIR/${sanitizeName f.name}.resync-done"
      LOCK_FILE="/run/synced-folders-${sanitizeName f.name}.lock"
      LOG_FILE="/var/log/synced-folders-${sanitizeName f.name}.log"

      log() {
        echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
        echo "$*"
      }

      mkdir -p "$LOCAL"
      chown ${f.owner}:${f.ownerGroup} "$LOCAL"
      mkdir -p "$STATE_DIR"

      # Serialise runs: skip if a previous sync is still going.
      exec 200>"$LOCK_FILE"
      if ! flock -n 200; then
        log "Another sync is already running, skipping"
        exit 0
      fi

      log "Starting bidirectional sync for ${f.name}"

      BISYNC_OPTS="--config $CONFIG"
      BISYNC_OPTS="$BISYNC_OPTS --ask-password=false"
      BISYNC_OPTS="$BISYNC_OPTS --filter-from $FILTER_FILE"
      BISYNC_OPTS="$BISYNC_OPTS --conflict-resolve newer"
      BISYNC_OPTS="$BISYNC_OPTS --resilient"
      BISYNC_OPTS="$BISYNC_OPTS --recover"
      BISYNC_OPTS="$BISYNC_OPTS --max-lock 2m"
      BISYNC_OPTS="$BISYNC_OPTS --max-delete ${toString f.maxDelete}"
      BISYNC_OPTS="$BISYNC_OPTS --check-access"
      BISYNC_OPTS="$BISYNC_OPTS -v"

      if [ ! -f "$STATE_FILE" ]; then
        log "First run detected, performing resync to establish baseline..."

        # RCLONE_TEST sentinels on both ends: with --check-access, a later sync
        # aborts if either side is missing this file (i.e. an empty/unmounted dir),
        # rather than mirroring the emptiness across and deleting everything.
        touch "$LOCAL/RCLONE_TEST" 2>/dev/null || true
        ${pkgs.rclone}/bin/rclone touch "$REMOTE/RCLONE_TEST" --config "$CONFIG" 2>/dev/null || true

        # --resync is destructive (it picks a winner and overwrites the other side).
        # Only record success in STATE_FILE so it runs exactly once, never again.
        if ${pkgs.rclone}/bin/rclone bisync "$LOCAL" "$REMOTE" $BISYNC_OPTS --resync 2>&1 | tee -a "$LOG_FILE"; then
          touch "$STATE_FILE"
          log "Initial resync completed successfully"
        else
          log "Initial resync failed"
          exit 1
        fi
      else
        if ${pkgs.rclone}/bin/rclone bisync "$LOCAL" "$REMOTE" $BISYNC_OPTS 2>&1 | tee -a "$LOG_FILE"; then
          log "Sync completed for ${f.name}"
        else
          log "Sync failed for ${f.name}"
          exit 1
        fi
      fi
    '';

in
{
  options.services.synced-folders = mkOption {
    type = types.listOf (types.submodule folderOpts);
    default = [ ];
    description = "List of folders to sync between this host and a remote over SFTP.";
    example = literalExpression ''
      [
        {
          name       = "repos";
          server     = "your-host";
          user       = "alice";
          sshKeyFile = "/home/alice/.ssh/id_ed25519";
          serverPath = "/home/alice/repos";
          localPath  = "/home/alice/repos";
          owner      = "alice";
          type       = "lazy";
          cacheDir   = "/var/cache/rclone-repos";
        }
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
      ]
    '';
  };

  config = mkIf (cfg != [ ]) {
    assertions =
      (map (f: {
        assertion = f.type == "full" || f.cacheDir != null;
        message = "synced-folders: folder '${f.name}' with type 'lazy' requires cacheDir to be set";
      }) cfg)
      ++ (map (f: {
        assertion = f.type == "full" || resolveUid f != null;
        message = "synced-folders: folder '${f.name}' (lazy) could not resolve a numeric uid; set `uid` explicitly or declare owner '${f.owner}' as a NixOS user";
      }) cfg)
      ++ (map (f: {
        assertion = f.type == "full" || resolveGid f != null;
        message = "synced-folders: folder '${f.name}' (lazy) could not resolve a numeric gid; set `gid` explicitly or declare group '${f.ownerGroup}'";
      }) cfg);

    programs.fuse.userAllowOther = mkIf (lazyFolders != [ ]) true;

    systemd.tmpfiles.rules = [
      "d /var/lib/synced-folders 0755 root root -"
    ]
    ++ (map (f: "d ${f.cacheDir} 0755 ${f.owner} ${f.ownerGroup} -") lazyFolders)
    ++ (map (
      f: "f /var/log/rclone-${sanitizeName f.name}.log 0644 ${f.owner} ${f.ownerGroup} -"
    ) lazyFolders)
    ++ (map (
      f: "f /var/log/synced-folders-${sanitizeName f.name}.log 0644 ${f.owner} ${f.ownerGroup} -"
    ) fullFolders)
    ++ (map (f: "d ${f.localPath} 0755 ${f.owner} ${f.ownerGroup} -") fullFolders);

    environment.etc."rclone/synced-folders.conf" = {
      text = rcloneConfig;
    };

    systemd.mounts = map (f: {
      where = f.localPath;
      what = "${sanitizeName f.name}:${f.serverPath}";
      type = "rclone";
      options = concatStringsSep "," [
        "_netdev"
        "args2env"
        "allow_other"
        "uid=${toString (resolveUid f)}"
        "gid=${toString (resolveGid f)}"
        "config=/etc/rclone/synced-folders.conf"
        "cache-dir=${f.cacheDir}"
        "vfs-cache-mode=full"
        "vfs-cache-max-age=${f.cacheMaxAge}"
        "vfs-cache-max-size=${f.cacheMaxSize}"
        "vfs-cache-poll-interval=${f.vfsCachePollInterval}"
        "vfs-read-chunk-size=4M"
        "vfs-read-chunk-size-limit=16M"
        "vfs-read-chunk-streams=8"
        "vfs-fast-fingerprint"
        "dir-cache-time=${f.dirCacheTime}"
        "poll-interval=${f.pollInterval}"
        "transfers=4"
        "checkers=8"
        "log-level=${f.logLevel}"
        "log-file=/var/log/rclone-${sanitizeName f.name}.log"
      ];
      unitConfig = {
        After = f.afterUnits;
        Wants = [ "network-online.target" ];
      };
    }) lazyFolders;

    systemd.automounts = map (f: {
      where = f.localPath;
      wantedBy = [ "multi-user.target" ];
      automountConfig = {
        TimeoutIdleSec = "10min";
      };
    }) lazyFolders;

    systemd.services = listToAttrs (
      map (f: {
        name = "synced-folders-${sanitizeName f.name}";
        value = {
          description = "Bidirectional sync for ${f.name}";
          after = f.afterUnits;
          wants = [ "network-online.target" ];
          path = [
            pkgs.rclone
            pkgs.util-linux
            pkgs.coreutils
          ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = mkSyncScript f;
            User = "root";
            TimeoutStartSec = "30min";
          };
        };
      }) fullFolders
    );

    systemd.timers = listToAttrs (
      map (f: {
        name = "synced-folders-${sanitizeName f.name}";
        value = {
          description = "Timer for bidirectional sync of ${f.name}";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = mkIf f.syncOnBoot "1min";
            OnUnitActiveSec = f.syncInterval;
            Persistent = true;
          };
        };
      }) fullFolders
    );

    environment.systemPackages = [ pkgs.rclone ];
  };
}
