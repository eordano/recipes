# shellcheck shell=bash

set -euo pipefail

data="${DROPBOX_DATA_DIR:?DROPBOX_DATA_DIR not set}"
worker="${DROPBOX_WORKER_UNIT:?DROPBOX_WORKER_UNIT not set}"
maxlen="${DROPBOX_MAX_ID_LEN:-128}"

shopt -s nullglob dotglob

log() { printf 'drop-box-dispatch: %s\n' "$*" >&2; }

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

for entry in "$data"/incoming/*/; do
  src="${entry%/}"
  id="${src##*/}"

  if ! id_is_safe "$id"; then
    digest="$(printf '%s' "$id" | sha256sum)"
    digest="${digest:0:16}"
    dest="$data/quarantine/rejected-$digest"
    mkdir -p -- "$data/quarantine"
    rm -rf -- "$dest"
    if mv -T -- "$src" "$dest"; then
      printf 'rejected drop name (must be 1..%s chars of [A-Za-z0-9._-], no leading dot)\n' \
        "$maxlen" >"$dest.reason"
      log "rejected an unsafe drop name -> quarantine/rejected-$digest"
    else
      log "WARN: could not quarantine an unsafe drop name"
    fi
    continue
  fi

  if [ -e "$data/published/$id" ] || [ -e "$data/quarantine/$id" ]; then
    continue
  fi

  esc="$(systemd-escape -- "$id")"
  systemctl start --no-block -- "${worker}${esc}.service" ||
    log "WARN: could not start worker for id $id"
done
