# mesh-node-reassociate — re-point a coordination-server node record at a
# specific overlay address (and optionally rename it) by editing the control
# plane's sqlite database directly.
#
# Configuration comes from the environment so the module wrapper can pin it:
#   MESH_CP_DB          sqlite database of the coordination server
#   MESH_CP_SERVICE     systemd unit to stop/start around the edit
#   MESH_CP_CLI         command used to probe the server's health afterwards
#   MESH_ADDR_PREFIXES  comma-separated address prefixes accepted by --to-ip
#   MESH_NODE_RESTART   command run over ssh to make the node re-poll

set -euo pipefail

DB="${MESH_CP_DB:-/var/lib/headscale/db.sqlite}"
SERVICE="${MESH_CP_SERVICE:-headscale}"
CLI="${MESH_CP_CLI:-headscale}"
PREFIXES="${MESH_ADDR_PREFIXES:-}"
NODE_RESTART="${MESH_NODE_RESTART:-systemctl restart tailscaled}"

from_id=""; from_ip=""; from_name=""
to_ip=""; to_name=""; to_ipv6=""
delete_conflict=0; steal_ipv6=0
node_ssh=""; dry_run=0; assume_yes=0; do_list=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
mesh-node-reassociate — re-point a coordination-server node at a specific
overlay address (and optionally rename it) via a direct sqlite edit.

A coordination server that allocates addresses sequentially hands a
re-registering node the next never-used address; it cannot give back the one
the node used to hold. So a node that re-registered under a fresh machine key
is put back on its canonical address by editing the database. This wraps that
edit: stop -> backup -> transaction -> start -> health-check -> nudge node.

Usage:
  mesh-node-reassociate --from-<id|ip|name>=X --to-ip=ADDR [options]

Select the LIVE node to modify (exactly one of):
  --from-id=ID            node id in the control-plane database
  --from-ip=ADDR          current overlay address of the node
  --from-name=NAME        current given-name of the node

Target:
  --to-ip=ADDR            overlay address to assign (required unless renaming)
  --to-name=NAME          also set the node's given-name
  --to-ipv6=ADDR          also set the node's IPv6 (default: keep current)

Handling the address's current holder (the stale shadow record):
  --delete-conflict       delete whatever node currently holds --to-ip/--to-name
  --steal-ipv6            when deleting a conflict, reuse its IPv6 for the node

Applying on the node:
  --node-ssh='SPEC'       ssh spec used to restart the mesh agent afterwards
                          (e.g. 'root@192.0.2.10 -p 22'); without it the node
                          adopts the new address on its next netmap poll
  --node-restart='CMD'    command to run there (default: $MESH_NODE_RESTART)

Other:
  --db=PATH               control-plane sqlite database
  --service=NAME          systemd unit to stop/start around the edit
  --list                  list nodes (id, name, ipv4, ipv6, user) and exit
  --dry-run               show the plan and the exact SQL, change nothing
  -y, --yes               do not prompt for confirmation
  -h, --help              this help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --from-id=*)       from_id="${arg#*=}" ;;
    --from-ip=*)       from_ip="${arg#*=}" ;;
    --from-name=*)     from_name="${arg#*=}" ;;
    --to-ip=*)         to_ip="${arg#*=}" ;;
    --to-name=*)       to_name="${arg#*=}" ;;
    --to-ipv6=*)       to_ipv6="${arg#*=}" ;;
    --node-ssh=*)      node_ssh="${arg#*=}" ;;
    --node-restart=*)  NODE_RESTART="${arg#*=}" ;;
    --db=*)            DB="${arg#*=}" ;;
    --service=*)       SERVICE="${arg#*=}" ;;
    --delete-conflict) delete_conflict=1 ;;
    --steal-ipv6)      steal_ipv6=1 ;;
    --dry-run)         dry_run=1 ;;
    --list)            do_list=1 ;;
    -y|--yes)          assume_yes=1 ;;
    -h|--help)         usage; exit 0 ;;
    *) die "unknown argument: $arg (see --help)" ;;
  esac
done

[ -r "$DB" ] || die "cannot read control-plane db at $DB (run as root on the coordination host)"

sql_stdin() { sqlite3 "$DB"; }
sql_ro()    { sqlite3 -readonly "$DB" "$@"; }

# The schema this tool understands: one row per node, with separate ipv4/ipv6
# columns and a mutable given_name. Older coordination servers kept addresses
# in a single serialised column under a differently named table; refuse those
# loudly instead of writing nonsense into them.
cols="$(sql_ro "SELECT ',' || group_concat(name) || ',' FROM pragma_table_info('nodes');")"
[ -n "$cols" ] || die "unexpected schema: $DB has no 'nodes' table — this tool targets a control plane that stores one row per node with per-address columns"
for c in id given_name ipv4 ipv6; do
  case "$cols" in
    *",$c,"*) ;;
    *) die "unexpected schema: table 'nodes' has no '$c' column (cols: ${cols//,/ }) — this tool targets a control plane with per-address columns" ;;
  esac
done

fmt_nodes() {
  sql_ro -cmd '.mode list' -cmd '.separator " | "' \
    "SELECT printf('%-4s',id), printf('%-16s',given_name), printf('%-16s',ipv4), printf('%-24s',ipv6), user_id FROM nodes ORDER BY CAST(id AS INT);"
}

if [ "$do_list" = 1 ]; then fmt_nodes; exit 0; fi

is_ipv4() {
  local o
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    if [ "$o" -gt 255 ]; then return 1; fi
  done
  return 0
}

# Guard rail: only accept addresses inside the overlay range. Without it a
# typo silently points a node at a public address and the control plane will
# happily serve that in the netmap.
in_overlay() {
  local p rest
  if [ -z "$PREFIXES" ]; then return 0; fi
  rest="$PREFIXES"
  while [ -n "$rest" ]; do
    p="${rest%%,*}"
    if [ "$p" = "$rest" ]; then rest=""; else rest="${rest#*,}"; fi
    case "$1" in "$p"*) return 0 ;; esac
  done
  return 1
}

safe_name() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,63}$ ]]; }

[ -n "$to_ip$to_name" ] || die "nothing to do: give --to-ip and/or --to-name"
if [ -n "$to_ip" ]; then
  is_ipv4 "$to_ip"   || die "--to-ip '$to_ip' is not an IPv4 address"
  in_overlay "$to_ip" || die "--to-ip '$to_ip' is outside the overlay prefixes ($PREFIXES)"
fi
if [ -n "$to_name" ]; then safe_name "$to_name" || die "--to-name '$to_name' has unexpected characters"; fi
if [ -n "$to_ipv6" ]; then [[ "$to_ipv6" =~ ^[0-9a-fA-F:]+$ ]] || die "--to-ipv6 '$to_ipv6' is not an IPv6 address"; fi

# Resolve the source node — exactly one. Every selector is validated before it
# reaches the SQL text, because these are interpolated, not bound.
sel=""
if [ -n "$from_id" ]; then
  [[ "$from_id" =~ ^[0-9]+$ ]] || die "--from-id must be numeric"
  sel="id = $from_id"
fi
if [ -n "$from_ip" ]; then
  is_ipv4 "$from_ip" || die "--from-ip '$from_ip' is not an IPv4 address"
  sel="ipv4 = '$from_ip'"
fi
if [ -n "$from_name" ]; then
  safe_name "$from_name" || die "--from-name '$from_name' has unexpected characters"
  sel="given_name = '$from_name'"
fi
[ -n "$sel" ] || die "select the node with one of --from-id / --from-ip / --from-name"

mapfile -t hits < <(sql_ro "SELECT id FROM nodes WHERE $sel;")
[ "${#hits[@]}" -eq 0 ] && die "no node matches ($sel)"
[ "${#hits[@]}" -gt 1 ] && die "ambiguous: ${#hits[@]} nodes match ($sel); use --from-id"
node_id="${hits[0]}"
read -r cur_name cur_ip4 cur_ip6 < <(sql_ro -cmd '.mode list' -cmd '.separator " "' \
  "SELECT given_name, ipv4, ipv6 FROM nodes WHERE id = $node_id;")

# Find the shadow: whatever record currently squats on the target address or
# name. That is normally the node's own earlier registration, left behind when
# it came back with a fresh machine key.
conflict_id=""; conflict_desc=""; conflict_ip6=""
if [ -n "$to_ip" ]; then
  conflict_id="$(sql_ro "SELECT id FROM nodes WHERE ipv4 = '$to_ip' AND id <> $node_id;")"
fi
if [ -z "$conflict_id" ] && [ -n "$to_name" ]; then
  conflict_id="$(sql_ro "SELECT id FROM nodes WHERE given_name = '$to_name' AND id <> $node_id;")"
fi
if [ -n "$conflict_id" ]; then
  read -r c_name c_ip4 conflict_ip6 < <(sql_ro -cmd '.mode list' -cmd '.separator " "' \
    "SELECT given_name, ipv4, ipv6 FROM nodes WHERE id = $conflict_id;")
  conflict_desc="id=$conflict_id name=$c_name ipv4=$c_ip4 ipv6=$conflict_ip6"
  [ "$delete_conflict" = 1 ] || die "target is held by another node ($conflict_desc); pass --delete-conflict to remove that shadow record"
fi

if [ -z "$to_ipv6" ] && [ "$steal_ipv6" = 1 ] && [ -n "$conflict_ip6" ]; then
  to_ipv6="$conflict_ip6"
fi

sets=()
[ -n "$to_ip" ]   && sets+=("ipv4 = '$to_ip'")
[ -n "$to_name" ] && sets+=("given_name = '$to_name'")
[ -n "$to_ipv6" ] && sets+=("ipv6 = '$to_ipv6'")
sets+=("updated_at = datetime('now')")
set_clause="$(IFS=,; echo "${sets[*]}")"

del_sql=""
[ -n "$conflict_id" ] && del_sql="DELETE FROM nodes WHERE id = $conflict_id;"
upd_sql="UPDATE nodes SET $set_clause WHERE id = $node_id;"

echo "== mesh-node-reassociate =="
echo "db:        $DB"
echo "node:      id=$node_id  name=$cur_name  ipv4=$cur_ip4  ipv6=$cur_ip6"
echo "new:       ipv4=${to_ip:-(unchanged)}  name=${to_name:-(unchanged)}  ipv6=${to_ipv6:-(unchanged)}"
[ -n "$conflict_id" ] && echo "delete:    shadow $conflict_desc"
echo "sql:"
[ -n "$del_sql" ] && echo "   $del_sql"
echo "   $upd_sql"

if [ "$dry_run" = 1 ]; then echo "(dry-run: no changes made)"; exit 0; fi

if [ "$assume_yes" != 1 ]; then
  printf 'proceed? this stops %s briefly [y/N] ' "$SERVICE"
  read -r ans; case "$ans" in y|Y|yes) ;; *) die "aborted";; esac
fi

[ "$(id -u)" -eq 0 ] || die "must run as root (needs to stop/start $SERVICE and write $DB)"

# Stop first, back up second. A running server holds recent writes in the -wal
# sidecar, so copying the main database file underneath it can capture a state
# that never existed. `.backup` after the stop takes a consistent snapshot.
echo "stopping $SERVICE ..."
systemctl stop "$SERVICE"

backup="$DB.bak-$(date +%Y-%m-%d-%H%M%S)-reassociate"
sqlite3 "$DB" ".backup '$backup'"
echo "backup:    $backup"

{
  echo "BEGIN IMMEDIATE;"
  [ -n "$del_sql" ] && printf '%s\n' "$del_sql"
  printf '%s\n' "$upd_sql"
  echo "COMMIT;"
} | sql_stdin

echo "starting $SERVICE ..."
systemctl start "$SERVICE"

ok=0
for _ in $(seq 1 30); do
  # shellcheck disable=SC2086 # $CLI may carry arguments
  if systemctl is-active --quiet "$SERVICE" && $CLI nodes list >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done
[ "$ok" = 1 ] || die "$SERVICE did not come back healthy; database backup at $backup"

echo "result:"
sql_ro -cmd '.mode list' -cmd '.separator " | "' \
  "SELECT id, given_name, ipv4, ipv6 FROM nodes WHERE id = $node_id;"

if [ -n "$to_ip" ]; then
  holders="$(sql_ro "SELECT count(*) FROM nodes WHERE ipv4 = '$to_ip';")"
  [ "$holders" = "1" ] || die "post-check: $holders nodes hold $to_ip (expected 1); backup at $backup"
fi

# The node keeps using its old address until it polls the control plane again.
if [ -n "$to_ip" ]; then
  if [ -n "$node_ssh" ]; then
    echo "restarting the mesh agent on the node ($node_ssh) ..."
    # shellcheck disable=SC2086
    if ssh -o ConnectTimeout=10 -o BatchMode=yes $node_ssh "$NODE_RESTART" 2>/dev/null; then
      echo "  agent restarted; node should now report $to_ip"
    else
      echo "  WARN: could not ssh to node; run '$NODE_RESTART' there manually"
    fi
  else
    echo "next: the node adopts $to_ip on its next netmap poll."
    echo "      to force it now: ssh <node> $NODE_RESTART"
  fi
fi

echo "done."
