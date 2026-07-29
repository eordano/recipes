# shellcheck shell=bash
#
# Client half of the drop-box: push a directory into a write-only SSH intake.
#
# Two rsync runs, in this order and never merged:
#   1. the payload
#   2. the sentinel, alone, AFTER run 1 has exited
#
# Merging them would defeat the whole point — rsync gives no ordering guarantee
# within one run, so the receiver could see the sentinel before the last file.
#
# Usage:
#   drop-box-push --target user@host --id 1738000000-abc1234-myproject ./result
#
# Options:
#   --target DEST     user@host of the receiver (or DROPBOX_TARGET)
#   --id ID           drop id; 1..128 chars of [A-Za-z0-9._-], no leading dot
#   --sentinel NAME   sentinel filename (default .done, or DROPBOX_SENTINEL)
#   --port N          ssh port
#   --dry-run         print the plan and exit
#   -h, --help        this text

set -euo pipefail
LC_ALL=C
export LC_ALL

TARGET="${DROPBOX_TARGET:-}"
ID=""
SENTINEL="${DROPBOX_SENTINEL:-.done}"
PORT="${DROPBOX_PORT:-}"
DRY_RUN=0
FOLDER=""

die() {
    printf 'drop-box-push: %s\n' "$*" >&2
    exit 2
}

usage() {
    cat <<'USAGE'
drop-box-push — push a directory into a write-only SSH drop-box

  drop-box-push --target user@host --id <id> [options] FOLDER

  --target DEST     user@host of the receiver (or DROPBOX_TARGET)
  --id ID           drop id; 1..128 chars of [A-Za-z0-9._-], no leading dot
  --sentinel NAME   sentinel filename (default .done, or DROPBOX_SENTINEL)
  --port N          ssh port (or DROPBOX_PORT)
  --dry-run         print the plan and exit
  -h, --help        this text

The payload and the sentinel are pushed as two separate rsync runs, in that
order. Never merge them: rsync gives no ordering guarantee within one run, so
the receiver could see the sentinel before the last file lands.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="${2:?--target needs a value}"; shift 2 ;;
        --id) ID="${2:?--id needs a value}"; shift 2 ;;
        --sentinel) SENTINEL="${2:?--sentinel needs a value}"; shift 2 ;;
        --port) PORT="${2:?--port needs a value}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h | --help) usage; exit 0 ;;
        --*) die "unknown flag: $1" ;;
        *)
            [ -z "$FOLDER" ] || die "unexpected positional: $1"
            FOLDER="$1"
            shift
            ;;
    esac
done

[ -n "$TARGET" ] || die "no --target (or DROPBOX_TARGET)"
[ -n "$FOLDER" ] || die "no folder given"
[ -n "$ID" ] || die "no --id"

# Mirror the receiver's rules so a bad id fails here, loudly, instead of
# landing in quarantine ten seconds later.
[ "${#ID}" -le 128 ] || die "id too long (${#ID} > 128)"
case "$ID" in
    .* | */* | *[[:space:]]*) die "id must not start with '.' or contain '/' or whitespace" ;;
esac
[ -z "${ID//[A-Za-z0-9._-]/}" ] || die "id has characters outside [A-Za-z0-9._-]"

# `nix build` leaves a symlink into a read-only store path; dereference it and
# stage a writable copy so rsync does not try to preserve 0444 store modes.
if [ -L "$FOLDER" ]; then
    FOLDER="$(readlink -f -- "$FOLDER")"
fi
[ -d "$FOLDER" ] || die "not a directory: $FOLDER"

SSH_CMD="ssh -o StrictHostKeyChecking=accept-new"
[ -z "$PORT" ] || SSH_CMD="$SSH_CMD -p $PORT"

if [ "$DRY_RUN" -eq 1 ]; then
    cat <<EOF
source:   $FOLDER
id:       $ID
target:   $TARGET:$ID/
plan:
  1) rsync -a --no-owner --no-group <staged>/ $TARGET:$ID/
  2) rsync -a --no-owner --no-group <empty>   $TARGET:$ID/$SENTINEL
EOF
    exit 0
fi

STAGING="$(mktemp -d -t drop-box-push.XXXXXXXX)"
SENTINEL_FILE="$(mktemp -t drop-box-sentinel.XXXXXXXX)"
cleanup() { rm -rf -- "$STAGING" "$SENTINEL_FILE"; }
trap cleanup EXIT

cp -rL -- "$FOLDER"/. "$STAGING"/
chmod -R u+rwX -- "$STAGING"

# The receiver chroots to incoming/, so the remote path is "<id>/", never
# "incoming/<id>/". Explicit --chmod because the sender's umask must not
# decide whether the receiver can read what it was given.
rsync -a -e "$SSH_CMD" --no-owner --no-group \
    --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r \
    "$STAGING"/ "$TARGET:$ID/"

: >"$SENTINEL_FILE"
rsync -a -e "$SSH_CMD" --no-owner --no-group \
    --chmod=Fu=rw,Fgo=r \
    "$SENTINEL_FILE" "$TARGET:$ID/$SENTINEL"

printf 'drop-box-push: pushed %s\n' "$ID" >&2
