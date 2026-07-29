# archive-organize-sync
#
# A timer-driven NixOS behavior that:
#   1. Organizes a local archive directory into YYYY.MM month folders (by mtime),
#   2. Additively rsyncs it to a remote/backup directory, then
#   3. Prunes local files older than N days — but ONLY after sha256-verifying
#      that an identical copy already exists on the remote.
#
# The important part is the ordering and the safety gate: organize -> sync ->
# verify -> prune. A local file is never deleted until its remote twin is
# proven byte-identical (sha256), so an interrupted or failed sync can never
# cause data loss. yt-dlp sidecar files (.info.json, thumbnails, subtitles) are
# kept grouped with their media by anchoring the whole group on the *media*
# file's date rather than each sidecar's own mtime.
#
# This module is self-contained: it ships both helper scripts inline, so you
# can drop it into any NixOS configuration and `import` it. Nothing outside
# this file is required.
#
# Usage:
#   imports = [ ./archive-organize-sync ];
#   services.archiveOrganizeSync = {
#     enable = true;
#     user = "alice";
#     localPath = "/home/alice/archive";
#     remotePath = "/mnt/backup/archive";
#     retentionDays = 14;
#     folders = [
#       { name = "downloads";   mode = "organize"; }   # organize + sync + prune
#       { name = "screenshots"; mode = "organize"; }
#       { name = "photos";      mode = "sync-only"; }   # never prune, never reorganize
#       { name = "videos";      mode = "ytdlp"; }       # organize keeping sidecars grouped
#     ];
#     defaultMode = "sync-prune";                       # any subdir not listed above
#   };

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.archiveOrganizeSync;

  # --- organize-yyyy-mm ----------------------------------------------------
  # Sorts loose entries in the current directory into YYYY.MM folders keyed on
  # each entry's mtime. A `.organize-yyyy-mm.config` keep-list (one name per
  # line, #-comments allowed) pins files that must never be sorted. With
  # `--ytdlp`, media files and their same-stem sidecars are moved together into
  # the media file's month, so an .info.json lands next to its video instead of
  # being sorted independently by its own (different) mtime.
  organize-yyyy-mm = pkgs.writeShellApplication {
    name = "organize-yyyy-mm";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      set -euo pipefail

      clobber=false
      dry_run=false
      ytdlp=false
      dir=""
      for arg in "$@"; do
        case "$arg" in
          --clobber) clobber=true ;;
          --dry-run|-n) dry_run=true ;;
          --ytdlp) ytdlp=true ;;
          *) dir="$arg" ;;
        esac
      done

      if [[ -n "$dir" ]]; then
        if [[ ! -d "$dir" ]]; then
          echo "Error: Directory '$dir' does not exist" >&2
          exit 1
        fi
        cd "$dir"
      fi

      get_date_folder() {
        local timestamp
        timestamp=$(stat -c %Y "$1")
        date -d "@$timestamp" +"%Y.%m"
      }

      move_entry() {
        local entry="$1" folder="$2"
        if [[ "$clobber" == false ]] && [[ -e "$folder/$entry" ]]; then
          echo "Skipping '$entry' (already exists in $folder/)" >&2
          return
        fi
        if [[ "$dry_run" == true ]]; then
          echo "Would move '$entry' to $folder/"
        else
          echo "Moving '$entry' to $folder/"
          mv "$entry" "$folder/"
        fi
      }

      shopt -s nullglob

      # Files that live in this directory permanently and must never be sorted
      # into a month folder. Read one filename per line from
      # .organize-yyyy-mm.config (in the directory being organized); blank lines
      # and #-comments are ignored.
      declare -A keep=()
      if [[ -f .organize-yyyy-mm.config ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
          line="''${line%%#*}"
          line="''${line#"''${line%%[![:space:]]*}"}"
          line="''${line%"''${line##*[![:space:]]}"}"
          [[ -z "$line" ]] && continue
          keep["$line"]=1
        done < .organize-yyyy-mm.config
      fi
      # Never sort the config file itself.
      keep[.organize-yyyy-mm.config]=1

      # Entries already placed by the --ytdlp pass, so the generic per-entry
      # pass below skips them (matters in --dry-run, where they're not actually
      # moved).
      declare -A grouped=()

      if [[ "$ytdlp" == true ]]; then
        # yt-dlp writes a media file plus sidecars (info.json, thumbnail,
        # subtitles) that share a stem but have different mtimes. Anchor each
        # group on its .info.json, then move the whole group into the *media*
        # file's month so the json info lands next to its video instead of
        # being sorted independently.
        for info in *.info.json; do
          stem="''${info%.info.json}"

          members=()
          for f in "$stem".*; do
            [[ -e "$f" ]] || continue
            members+=("$f")
          done

          # The media file is the largest member that isn't the info.json; it
          # sets the group's folder. If there's no media (download failed, json
          # only), fall back to the info.json's own date.
          media=""
          media_size=-1
          for m in "''${members[@]}"; do
            [[ "$m" == "$info" ]] && continue
            size=$(stat -c %s "$m")
            if (( size > media_size )); then
              media_size=$size
              media="$m"
            fi
          done

          folder=$(get_date_folder "''${media:-$info}")
          mkdir -p "$folder"
          for m in "''${members[@]}"; do
            move_entry "$m" "$folder"
            grouped["$m"]=1
          done
        done
      fi

      for entry in *; do
        if [[ "$entry" =~ ^20[0-9][0-9]\.[0-9][0-9]$ ]]; then
          continue
        fi
        [[ -n "''${keep[$entry]:-}" ]] && continue
        [[ -n "''${grouped[$entry]:-}" ]] && continue

        folder=$(get_date_folder "$entry")
        mkdir -p "$folder"
        move_entry "$entry" "$folder"
      done
    '';
  };

  # --- routing table -------------------------------------------------------
  # Build the bash associative array that maps a subdirectory name to its mode.
  folderModeLines = lib.concatMapStringsSep "\n" (
    f: "MODE[${lib.escapeShellArg f.name}]=${lib.escapeShellArg f.mode}"
  ) cfg.folders;

  # --- archive-sync-start --------------------------------------------------
  # Walks each immediate subdirectory of LOCAL_PATH and applies its mode:
  #
  #   organize    organize into YYYY.MM, sync to remote, prune verified-synced
  #               files older than retentionDays
  #   ytdlp       like organize but keeps yt-dlp sidecars grouped with media
  #   ytdlp-only  like ytdlp but never prunes -- for a library the remote is a
  #               backup of rather than an offload target
  #   sync-only   sync to remote, never reorganize, never prune
  #   sync-prune  sync to remote, prune verified-synced old files (no reorganize)
  #
  # Prune is gated on a sha256 match against the remote copy: a local file is
  # removed only once its remote twin is proven byte-identical.
  archive-sync-start = pkgs.writeShellApplication {
    name = "archive-sync-start";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      rsync
      organize-yyyy-mm
    ];
    text = ''
      set -euo pipefail

      if [ "$#" -lt 2 ]; then
        echo "Usage: $0 LOCAL_PATH REMOTE_PATH [RETENTION_DAYS] [DEFAULT_MODE]" >&2
        exit 1
      fi

      LOCAL_PATH=$(realpath "$1")
      REMOTE_PATH=$(realpath -m "$2")
      RETENTION_DAYS="''${3:-14}"
      DEFAULT_MODE="''${4:-sync-prune}"

      # Subdirectory -> mode routing table (populated from module options).
      declare -A MODE=()
      ${folderModeLines}

      ORIGINAL_DIR=$(pwd)
      trap 'cd "$ORIGINAL_DIR"' EXIT

      log() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
      }

      mkdir -p "$REMOTE_PATH"

      # Additive rsync: copy new/changed files to the remote, never delete
      # there. The remote is the durable side.
      sync_files() {
        local source="$1" target="$2"
        mkdir -p "$target"
        log "Syncing files from $source to $target"
        if ! rsync -av "$source/" "$target/"; then
          log "Error: rsync failed for $source to $target"
          return 1
        fi
      }

      # Prune local files older than RETENTION_DAYS, but only after proving the
      # remote copy is byte-identical (sha256). This is the safety gate: an
      # interrupted or partial sync can never cause local data loss.
      delete_old_files() {
        local source="$1" target="$2"
        log "Checking for old files to delete in $source"
        find "$source" -type f -mtime "+$RETENTION_DAYS" -print0 |
          while read -d "" -r source_file; do
            rel_path="''${source_file#"$source"/}"
            target_file="$target/$rel_path"
            if [ -f "$target_file" ] &&
               [ "$(sha256sum "$source_file" | cut -d' ' -f1)" = \
                 "$(sha256sum "$target_file" | cut -d' ' -f1)" ]; then
              log "Deleting verified old file: $source_file"
              rm "$source_file"
            fi
          done
      }

      # Organize a yt-dlp-style download dir: move media into YYYY.MM, then move
      # each .info.json next to whichever media file it belongs to.
      organize_videos() {
        local dir="$1"
        log "Organizing videos in $dir"
        cd "$dir"
        if ! organize-yyyy-mm --ytdlp; then
          log "Error: organize-yyyy-mm failed for $dir"
          return 1
        fi
      }

      log "Starting directory processing from $LOCAL_PATH"
      find "$LOCAL_PATH" -mindepth 1 -maxdepth 1 -type d -print0 |
        while read -d "" -r dir; do
          dir_name=$(basename "$dir")
          mode="''${MODE[$dir_name]:-$DEFAULT_MODE}"
          log "Processing directory: $dir_name (mode: $mode)"

          case "$mode" in
            organize)
              cd "$dir" && organize-yyyy-mm
              sync_files "$dir" "$REMOTE_PATH/$dir_name"
              delete_old_files "$dir" "$REMOTE_PATH/$dir_name"
              ;;
            ytdlp)
              organize_videos "$dir"
              sync_files "$dir" "$REMOTE_PATH/$dir_name"
              delete_old_files "$dir" "$REMOTE_PATH/$dir_name"
              ;;
            ytdlp-only)
              organize_videos "$dir"
              sync_files "$dir" "$REMOTE_PATH/$dir_name"
              ;;
            sync-only)
              sync_files "$dir" "$REMOTE_PATH/$dir_name"
              ;;
            sync-prune|*)
              sync_files "$dir" "$REMOTE_PATH/$dir_name"
              delete_old_files "$dir" "$REMOTE_PATH/$dir_name"
              ;;
          esac
        done

      log "Archive sync completed successfully"
    '';
  };

  folderModule = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Immediate subdirectory of localPath this rule applies to.";
      };
      mode = lib.mkOption {
        type = lib.types.enum [
          "organize"
          "ytdlp"
          "ytdlp-only"
          "sync-only"
          "sync-prune"
        ];
        default = "sync-prune";
        description = ''
          How to process this subdirectory:
          - organize:   sort into YYYY.MM, sync, prune verified-synced old files
          - ytdlp:      like organize but keep yt-dlp sidecars grouped with media
          - ytdlp-only: like ytdlp but never prune
          - sync-only:  sync to remote, never reorganize or prune
          - sync-prune: sync to remote, prune verified-synced old files (no sort)
        '';
      };
    };
  };
in
{
  options.services.archiveOrganizeSync = {
    enable = lib.mkEnableOption "archive organize-then-sync-then-prune timer";

    user = lib.mkOption {
      type = lib.types.str;
      default = "archive";
      description = "User the oneshot runs as. Set this to the owner of localPath.";
    };

    localPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/archive";
      example = "/home/alice/archive";
      description = "Local archive directory whose immediate subdirectories are processed.";
    };

    remotePath = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/backup/archive";
      example = "/srv/archive";
      description = ''
        Destination the archive is additively rsynced into. For an off-host
        target, point this at a locally-mounted path (NFS, sshfs, rclone mount,
        etc.) — the module uses a plain filesystem rsync so the durable copy can
        be verified with sha256 before local pruning.
      '';
    };

    retentionDays = lib.mkOption {
      type = lib.types.int;
      default = 14;
      description = ''
        Prune local files older than this many days — but only once an
        identical (sha256) copy is confirmed present on the remote.
      '';
    };

    folders = lib.mkOption {
      type = lib.types.listOf folderModule;
      default = [ ];
      example = lib.literalExpression ''
        [
          { name = "downloads";   mode = "organize"; }
          { name = "screenshots"; mode = "organize"; }
          { name = "photos";      mode = "sync-only"; }
          { name = "videos";      mode = "ytdlp"; }
        ]
      '';
      description = "Per-subdirectory processing rules. Unlisted subdirectories use defaultMode.";
    };

    defaultMode = lib.mkOption {
      type = lib.types.enum [
        "organize"
        "ytdlp"
        "ytdlp-only"
        "sync-only"
        "sync-prune"
      ];
      default = "sync-prune";
      description = "Mode applied to any subdirectory of localPath not named in `folders`.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "systemd OnCalendar expression for how often to run.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.archive-organize-sync = {
      description = "Archive organize, sync, and verified-prune";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        ExecStart = lib.escapeShellArgs [
          "${archive-sync-start}/bin/archive-sync-start"
          cfg.localPath
          cfg.remotePath
          (toString cfg.retentionDays)
          cfg.defaultMode
        ];
      };
    };

    systemd.timers.archive-organize-sync = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
      };
    };

    environment.systemPackages = [
      archive-sync-start
      organize-yyyy-mm
    ];
  };
}
