# shellcheck shell=bash
#
# Fan a single inotify event out into one worker per unprocessed drop.
#
# The path unit is edge-triggered and coalescing: a burst of pushes may produce
# one activation or twenty, and there is no way to learn *which* directory
# moved from the event itself. So the dispatcher re-derives the work list from
# the filesystem every time and skips anything already dealt with. Running it
# spuriously must be free.
#
# Environment (all set by the NixOS module):
#   DROPBOX_DATA_DIR    root that holds incoming/ published/ quarantine/
#   DROPBOX_WORKER_UNIT templated unit prefix, e.g. "drop-box-promote@"
#   DROPBOX_MAX_ID_LEN  maximum id length (default: 128)

set -euo pipefail

data="${DROPBOX_DATA_DIR:?DROPBOX_DATA_DIR not set}"
worker="${DROPBOX_WORKER_UNIT:?DROPBOX_WORKER_UNIT not set}"
maxlen="${DROPBOX_MAX_ID_LEN:-128}"

# dotglob so a drop named `.evil` is quarantined rather than accumulating
# invisibly forever. `*` still never matches `.` or `..`.
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
        # `$src` is a glob result, so it is a real path with no traversal in
        # it no matter what the uploader called the directory. The *name* is
        # still unsafe to reuse, so quarantine under a digest of it.
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

    # `systemd-escape --` keeps an id that begins with `-` from being parsed
    # as an option, and the started unit name always begins with the worker
    # prefix, so the escaped id can never become a systemctl flag either.
    esc="$(systemd-escape -- "$id")"
    systemctl start --no-block -- "${worker}${esc}.service" \
        || log "WARN: could not start worker for id $id"
done
