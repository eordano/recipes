# shellcheck shell=bash

set -euo pipefail

data="${DROPBOX_DATA_DIR:?DROPBOX_DATA_DIR not set}"
sentinel="${DROPBOX_SENTINEL:-.done}"
timeout="${DROPBOX_DONE_TIMEOUT:-120}"
maxlen="${DROPBOX_MAX_ID_LEN:-128}"
validate_hook="${DROPBOX_VALIDATE_HOOK:-}"
promoted_hook="${DROPBOX_ON_PROMOTED:-}"
quarantined_hook="${DROPBOX_ON_QUARANTINED:-}"

id="${1:-}"

log() { printf 'drop-box[%s]: %s\n' "${id:-<empty>}" "$*" >&2; }

id_is_safe() {
  local v="$1"
  [ -n "$v" ] || return 1
  [ "${#v}" -le "$maxlen" ] || return 1
  case "$v" in
    .* | */* | *[[:space:]]*) return 1 ;;
  esac
  [ -z "${v//[A-Za-z0-9._-]/}" ] || return 1
  return 0
}

if ! id_is_safe "$id"; then
  log "refusing to act: id fails validation (no path is built from it)"
  exit 0
fi

incoming="$data/incoming/$id"
published="$data/published/$id"
quarantine="$data/quarantine/$id"
reason_file="$data/quarantine/$id.reason"

quarantine_upload() {
  local reason="$1"
  log "quarantining: $reason"
  mkdir -p -- "$data/quarantine"
  rm -rf -- "$quarantine"
  if [ -e "$incoming" ]; then
    mv -T -- "$incoming" "$quarantine" ||
      log "WARN: could not move incoming/$id into quarantine/$id"
  fi
  printf '%s\n' "$reason" >"$reason_file"
  if [ -n "$quarantined_hook" ]; then
    DROPBOX_ID="$id" \
      DROPBOX_DATA_DIR="$data" \
      DROPBOX_PATH="$quarantine" \
      DROPBOX_REASON="$reason" \
      "$quarantined_hook" || log "WARN: onQuarantined hook failed"
  fi
  exit 0
}

if [ ! -d "$incoming" ]; then
  log "incoming/$id is gone; nothing to do"
  exit 0
fi

mkdir -p -- "$data/work"
exec 9>"$data/work/$id.lock"
if ! flock -n 9; then
  log "another worker holds the lock for this id; leaving it to them"
  exit 0
fi

if [ ! -d "$incoming" ]; then
  log "incoming/$id disappeared before the lock was taken"
  exit 0
fi
if [ -e "$published" ]; then
  quarantine_upload "duplicate id: published/$id already exists"
fi

deadline=$(($(date +%s) + timeout))
while [ ! -f "$incoming/$sentinel" ]; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    quarantine_upload "incomplete upload: sentinel '$sentinel' not seen within ${timeout}s"
  fi
  sleep 1
  if [ ! -d "$incoming" ]; then
    log "incoming/$id disappeared while waiting for '$sentinel'"
    exit 0
  fi
done

if [ -n "$validate_hook" ]; then
  hook_output=""
  if ! hook_output="$(
    cd "$incoming" &&
      DROPBOX_ID="$id" DROPBOX_DATA_DIR="$data" DROPBOX_PATH="$incoming" \
        "$validate_hook" 2>&1
  )"; then
    reason="${hook_output:-validate hook rejected the upload}"
    quarantine_upload "$(printf '%s' "$reason" | head -n 5)"
  fi
fi

mkdir -p -- "$data/published"
if ! mv -T -- "$incoming" "$published" 2>/dev/null; then
  quarantine_upload "could not move into published/$id (destination appeared during promotion?)"
fi

published_root="$(realpath -- "$data/published")"
landed="$(realpath -- "$published")"
case "$landed" in
  "$published_root"/*) ;;
  *)
    log "FATAL: published/$id resolved to $landed, outside $published_root"
    exit 1
    ;;
esac

log "promoted -> published/$id"

if [ -n "$promoted_hook" ]; then
  DROPBOX_ID="$id" \
    DROPBOX_DATA_DIR="$data" \
    DROPBOX_PATH="$published" \
    "$promoted_hook" || log "WARN: onPromoted hook failed"
fi
