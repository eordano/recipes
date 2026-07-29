#!/usr/bin/env bash
#
# nix-builder-bench — measure candidate Nix remote builders so that the
# `speedFactor` you write into nix.buildMachines is a number you can defend.
#
# Design constraints (see the recipe README for why each one matters):
#
#   * ONE generated program is piped into ONE `bash -s` per host, and that
#     program `exec`s into ONE `nix shell`. Every benchmark therefore runs
#     under the identical toolchain with no PATH drift between measurements,
#     and the nix-shell realisation cost is paid once, outside the timings.
#   * hyperfine does the timing, with warmup runs discarded, so the first
#     (cold page cache, cold nix db) iteration never lands in the median.
#   * the nix_build micro-benchmark puts $RANDOM$$ in the derivation name so
#     it is a genuine cache miss on every iteration — otherwise you are
#     timing a store lookup, and every machine looks equally fast.
#   * SSH multiplexing is turned on explicitly HERE (with an explicit
#     ControlPath, and `ssh -O exit` against that same path in the EXIT trap)
#     because a command-line -o beats ssh_config, and because the builder
#     blocks in ssh_config deliberately turn multiplexing OFF.
#
# Host table, in precedence order:
#   1. positional arguments:  nix-builder-bench 'boxA | ssh boxA' 'here | local'
#   2. $BENCH_HOSTS_FILE      one entry per line, same format
#   3. $BENCH_HOSTS           newline-separated, same format
# Format is "label | command", where command is anything that accepts a
# program on stdin (usually `ssh <alias>`), or the literal word `local`.
#
# Tunables (all optional):
#   BENCH_LIST          space-separated benchmark names (default: all but disk_rand/mem_bw)
#   BENCH_RUNS          hyperfine measurement runs   (default 3)
#   BENCH_WARMUP        hyperfine warmup runs        (default 1, discarded)
#   BENCH_DISK_SIZE_MB  fio working-set size in MiB  (default 256)
#   BENCH_NIX_PKGS      flake refs realised on the remote for the toolchain
#   RESULTS_DIR         where per-host logs and results.tsv land

set -euo pipefail

read -ra BENCHMARKS <<< "${BENCH_LIST:-sysinfo cpu_single cpu_multi disk_seq nix_eval nix_build}"

DISK_SIZE_MB="${BENCH_DISK_SIZE_MB:-256}"
HF_RUNS="${BENCH_RUNS:-3}"
HF_WARMUP="${BENCH_WARMUP:-1}"

NIX_PKGS="${BENCH_NIX_PKGS:-nixpkgs#hyperfine nixpkgs#fio nixpkgs#coreutils nixpkgs#jq nixpkgs#bash}"

RESULTS_DIR="${RESULTS_DIR:-/tmp/nix-builder-bench-$(date +%Y%m%d-%H%M%S)}"

SSH_CTRL_DIR="$(mktemp -d -t bench-ssh.XXXXXX)"
mkdir -p "$RESULTS_DIR"
TSV="$RESULTS_DIR/results.tsv"
printf 'host\tbenchmark\tstatus\tmetrics\n' > "$TSV"

declare -a HOST_LABELS=()
declare -A HOST_SPEC=()

# Tear the multiplexed masters down explicitly. `ssh -O exit` can only find a
# socket it is told about, so the ControlPath here MUST be spelled exactly as
# it was when the master was started — there is no "the" control path to
# inherit, and a leaked master keeps a session (and its environment) alive
# well past the end of this script.
cleanup() {
  local label spec
  (( ${#HOST_LABELS[@]} == 0 )) && return 0
  for label in "${HOST_LABELS[@]}"; do
    [[ -z "$label" ]] && continue
    spec="${HOST_SPEC[$label]:-}"
    [[ -z "$spec" || "$spec" == "local" ]] && continue
    read -ra parts <<< "$spec"
    "${parts[0]}" -o "ControlPath=$SSH_CTRL_DIR/%r@%h:%p" \
      -O exit "${parts[@]:1}" 2>/dev/null || true
  done
  rm -rf "$SSH_CTRL_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*" >&2; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Multiplexing is requested on the COMMAND LINE, not in ssh_config. ssh reads
# command-line -o first and first-obtained-value wins, so this works even
# though the builder's ssh_config block says `ControlMaster no` — and the
# builder's block keeps saying no for everyone else, which is the point.
remote_bash() {
  local label="$1" spec="$2"
  if [[ "$spec" == "local" ]]; then
    bash
  else
    read -ra parts <<< "$spec"
    "${parts[0]}" \
      -o ControlMaster=auto \
      -o "ControlPath=$SSH_CTRL_DIR/%r@%h:%p" \
      -o ControlPersist=60s \
      -o BatchMode=yes \
      -o ServerAliveInterval=30 \
      "${parts[@]:1}" bash -s
  fi
}

# One `exec nix shell` for the whole program. Everything after this line runs
# inside that shell, so hyperfine/fio/jq/coreutils are the SAME builds for
# every benchmark on every host, and the realisation cost is paid once and
# outside the measured region.
remote_header() {
  cat <<EOF
set -eu
export DISK_SIZE_MB=$DISK_SIZE_MB
export HF_RUNS=$HF_RUNS
export HF_WARMUP=$HF_WARMUP
exec nix shell $NIX_PKGS --command bash -s <<'__NIXBENCH_INNER__'
set -eu
EOF
}

remote_helpers() {
  cat <<'EOF'
# hf <shell-command-string>
# Runs the command under hyperfine (warmup + N runs), emits one line:
#   seconds=<median> min=<m> max=<M> p95=<p> stddev=<s> runs=<n> status=ok
# or "status=fail ..." on error. The warmup runs are DISCARDED by hyperfine,
# which is what keeps a cold cache out of the median.
hf() {
  local tmp
  tmp=$(mktemp)
  if hyperfine --style none \
      --warmup "$HF_WARMUP" --runs "$HF_RUNS" \
      --export-json "$tmp" "$1" >/dev/null 2>&1; then
    # Compute p95 from the sorted per-iteration times.
    jq -r '.results[0] as $r
      | ($r.times | sort) as $t
      | ($t | length) as $n
      | ($t[ (($n - 1) * 0.95) | floor ]) as $p95
      | "seconds=" + ($r.median|tostring)
        + " min="    + ($r.min|tostring)
        + " max="    + ($r.max|tostring)
        + " p95="    + ($p95|tostring)
        + " stddev=" + (($r.stddev // 0)|tostring)
        + " runs="   + ($n|tostring)
        + " status=ok"' "$tmp"
  else
    echo "status=fail cmd=$1"
  fi
  rm -f "$tmp"
}

ncpu() { nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1; }
EOF
}

remote_footer() {
  echo '__NIXBENCH_INNER__'
}

bench_sysinfo() {
  cat <<'EOF'
os=$(uname -s)
arch=$(uname -m)
kernel=$(uname -r 2>/dev/null || echo "?")
cpus=$(ncpu)
if command -v free >/dev/null 2>&1; then
  mem=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')
elif command -v sysctl >/dev/null 2>&1; then
  bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  mem="$((bytes / 1073741824))G"
else
  mem="?"
fi
nixver=$(nix --version 2>/dev/null | awk '{print $NF; exit}' || echo missing)
gpu=none
if command -v nvidia-smi >/dev/null 2>&1; then
  # nvidia-smi exits non-zero and prints a paragraph of prose when the driver
  # is absent; without the exit-status test that paragraph lands in the table.
  if out=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null); then
    out=$(printf '%s' "$out" | head -1 | tr ' ' '_')
    [ -n "$out" ] && gpu="$out"
  fi
fi
printf 'os=%s arch=%s kernel=%s cpus=%s mem=%s gpu=%s nix=%s status=ok\n' \
  "$os" "$arch" "$kernel" "$cpus" "$mem" "$gpu" "$nixver"
EOF
}

bench_cpu_single() {
  cat <<'EOF'
hf 'dd if=/dev/zero bs=1M count=512 status=none | sha256sum >/dev/null'
EOF
}

bench_cpu_multi() {
  cat <<'EOF'
n=$(ncpu)
hf "seq 1 $n | xargs -P$n -I{} sh -c 'dd if=/dev/zero bs=1M count=256 status=none | sha256sum >/dev/null'"
EOF
}

bench_disk_seq() {
  cat <<'EOF'
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
json=$(fio --name=bench --directory="$dir" --rw=rw --bs=1M \
  --size="${DISK_SIZE_MB}M" --direct=0 --fsync=1 \
  --output-format=json --loops=1 --group_reporting=1 2>/dev/null) || {
    echo "status=fail stage=fio"; exit 0
}
w_kbps=$(printf '%s' "$json" | jq -r '.jobs[0].write.bw')
r_kbps=$(printf '%s' "$json" | jq -r '.jobs[0].read.bw')
runtime_ms=$(printf '%s' "$json" | jq -r '.jobs[0].write.runtime + .jobs[0].read.runtime')
seconds=$(awk "BEGIN{printf \"%.3f\", $runtime_ms / 1000}")
w_mbps=$(awk "BEGIN{printf \"%.1f\", $w_kbps / 1024}")
r_mbps=$(awk "BEGIN{printf \"%.1f\", $r_kbps / 1024}")
printf 'seconds=%s write_MBs=%s read_MBs=%s status=ok\n' "$seconds" "$w_mbps" "$r_mbps"
EOF
}

bench_disk_rand() {
  cat <<'EOF'
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
json=$(fio --name=randrw --directory="$dir" --rw=randrw --bs=4k \
  --size="${DISK_SIZE_MB}M" --iodepth=1 --direct=0 --fsync=16 \
  --output-format=json --loops=1 2>/dev/null) || {
    echo "status=fail stage=fio"; exit 0
}
w_iops=$(printf '%s' "$json" | jq -r '.jobs[0].write.iops | floor')
r_iops=$(printf '%s' "$json" | jq -r '.jobs[0].read.iops | floor')
runtime_ms=$(printf '%s' "$json" | jq -r '.jobs[0].write.runtime')
seconds=$(awk "BEGIN{printf \"%.3f\", $runtime_ms / 1000}")
printf 'seconds=%s write_iops=%s read_iops=%s status=ok\n' "$seconds" "$w_iops" "$r_iops"
EOF
}

bench_mem_bw() {
  cat <<'EOF'
hf 'dd if=/dev/zero of=/dev/null bs=1M count=1024 status=none'
EOF
}

bench_nix_eval() {
  cat <<'EOF'
hf 'nix eval --impure --expr "builtins.length (builtins.genList (i: i) 100000)"'
EOF
}

# $RANDOM$$ makes every iteration a derivation Nix has never seen, so this
# measures a real build round-trip (hash, write .drv, fork the builder, register
# the output) instead of a store hit. Without it every host reports the same
# few milliseconds and the benchmark is worthless.
#
# --builders '' is equally load-bearing: a host that already HAS remote
# builders configured forwards this derivation straight back out over the
# network, and you end up timing some third machine. (It only works if you are
# a trusted user there; otherwise Nix ignores the flag and says so.)
#
# builtins.storePath, not a bare string: a plain "/nix/store/…" literal carries
# no string context, so it is not an input of the derivation and the build
# sandbox does not bind-mount it — the build then dies with
# `error: executing '/nix/store/…/bin/bash': No such file or directory`.
bench_nix_build() {
  cat <<'EOF'
BASH_ROOT=$(dirname "$(dirname "$(command -v bash)")")
hf "R=\$RANDOM\$\$; nix build --impure --no-link --builders '' --expr \"derivation { name = \\\"bench-\$R\\\"; system = builtins.currentSystem; builder = \\\"\\\${builtins.storePath \\\"$BASH_ROOT\\\"}/bin/bash\\\"; args = [ \\\"-c\\\" \\\"echo hi > \\\$out\\\" ]; }\" 2>/dev/null"
EOF
}

run_host() {
  local label="$1" spec="$2"
  local logfile="$RESULTS_DIR/$label.log"
  local frag="$RESULTS_DIR/$label.tsv"

  log "$label: starting"

  {
    remote_header
    remote_helpers
    echo
    for b in "${BENCHMARKS[@]}"; do
      printf '\necho "=== BENCH:%s ==="\n' "$b"
      printf '( %s ) 2>&1 || echo "status=fail stage=subshell"\n' "$(bench_"$b")"
    done
    remote_footer
  } | remote_bash "$label" "$spec" > "$logfile" 2>&1 \
    || log "$label: remote exited non-zero (see $logfile)"

  : > "$frag"
  local current="" buffer="" status
  while IFS= read -r line; do
    if [[ "$line" =~ ^===\ BENCH:([a-z_]+)\ ===$ ]]; then
      if [[ -n "$current" ]]; then
        status="fail"
        [[ "$buffer" == *"status=ok"* ]] && status="ok"
        printf '%s\t%s\t%s\t%s\n' "$label" "$current" "$status" "$buffer" >> "$frag"
      fi
      current="${BASH_REMATCH[1]}"
      buffer=""
    else
      [[ -z "$line" ]] && continue
      [[ -n "$buffer" ]] && buffer+=" "
      buffer+="$line"
    fi
  done < "$logfile"
  if [[ -n "$current" ]]; then
    status="fail"
    [[ "$buffer" == *"status=ok"* ]] && status="ok"
    printf '%s\t%s\t%s\t%s\n' "$label" "$current" "$status" "$buffer" >> "$frag"
  fi

  log "$label: done ($(wc -l <"$frag") benches logged)"
}

add_entry() {
  local entry label spec
  entry="$1"
  [[ -z "$(trim "$entry")" ]] && return 0
  [[ "$(trim "$entry")" == \#* ]] && return 0
  if [[ "$entry" != *"|"* ]]; then
    log "skip malformed host (no '|'): $entry"
    return 0
  fi
  label="$(trim "${entry%%|*}")"
  spec="$(trim "${entry#*|}")"
  if [[ -z "$label" || -z "$spec" ]]; then
    log "skip malformed host: $entry"
    return 0
  fi
  HOST_LABELS+=("$label")
  HOST_SPEC[$label]="$spec"
}

if (( $# > 0 )); then
  for entry in "$@"; do add_entry "$entry"; done
elif [[ -n "${BENCH_HOSTS_FILE:-}" && -r "${BENCH_HOSTS_FILE}" ]]; then
  while IFS= read -r entry; do add_entry "$entry"; done < "$BENCH_HOSTS_FILE"
elif [[ -n "${BENCH_HOSTS:-}" ]]; then
  while IFS= read -r entry; do add_entry "$entry"; done <<< "$BENCH_HOSTS"
fi

if (( ${#HOST_LABELS[@]} == 0 )); then
  cat >&2 <<'USAGE'
No hosts configured.

  nix-builder-bench 'label | ssh alias' ['other | ssh other'] ...
  BENCH_HOSTS_FILE=/path/to/hosts nix-builder-bench
  BENCH_HOSTS=$'a | ssh a\nhere | local' nix-builder-bench

Each entry is "label | command"; command reads a program on stdin
(normally `ssh <alias>`) or is the literal word `local`.
USAGE
  exit 1
fi

bar=$(printf '=%.0s' {1..64})
echo "$bar"
echo "Nix Builder Benchmark — $(date)"
echo "$bar"
printf '  %-10s %s\n' "hosts:" "${HOST_LABELS[*]}"
printf '  %-10s %s\n' "benches:" "${BENCHMARKS[*]}"
printf '  %-10s %s\n' "results:" "$RESULTS_DIR"
printf '  %-10s %s\n' "tsv:" "$TSV"
echo "$bar"
echo

pids=()
for label in "${HOST_LABELS[@]}"; do
  run_host "$label" "${HOST_SPEC[$label]}" &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "$pid" || true
done

for label in "${HOST_LABELS[@]}"; do
  [[ -s "$RESULTS_DIR/$label.tsv" ]] && cat "$RESULTS_DIR/$label.tsv" >> "$TSV"
done

echo
python3 - "$TSV" "$RESULTS_DIR" <<'PYEOF'
import csv, sys, os, re
from collections import OrderedDict

tsv_path, results_dir = sys.argv[1], sys.argv[2]

# ── Color ─────────────────────────────────────────────────────────
USE_COLOR = (sys.stdout.isatty() or os.environ.get('FORCE_COLOR')) and not os.environ.get('NO_COLOR')
def c(code, s):
    return f"\033[{code}m{s}\033[0m" if USE_COLOR else str(s)
BOLD = lambda s: c('1', s)
DIM  = lambda s: c('2;37', s)
RED  = lambda s: c('31', s)
GRN  = lambda s: c('32', s)
YEL  = lambda s: c('33', s)
CYN  = lambda s: c('36', s)

def strip_ansi(s): return re.sub(r'\033\[[0-9;]*m', '', s)
def vlen(s):       return len(strip_ansi(s))
def pad(s, w, right=False):
    n = max(0, w - vlen(s))
    return (' ' * n + s) if right else (s + ' ' * n)

def section(title, subtitle=''):
    head = BOLD(CYN('━━━ ' + title + ' ━━━'))
    if subtitle:
        head += '  ' + DIM(subtitle)
    print('\n' + head)

# ── Parse TSV ─────────────────────────────────────────────────────
def parse_kv(s):
    out = {}
    for tok in s.split():
        if '=' in tok:
            k, v = tok.split('=', 1)
            out[k] = v
    return out

rows = []
with open(tsv_path) as f:
    reader = csv.reader(f, delimiter='\t')
    next(reader, None)
    for r in reader:
        if len(r) < 4: continue
        rows.append({'host': r[0], 'bench': r[1], 'status': r[2], 'm': parse_kv(r[3])})

if not rows:
    print("(no results)"); sys.exit(0)

hosts   = list(OrderedDict((r['host'],  None) for r in rows))
benches = list(OrderedDict((r['bench'], None) for r in rows))

# ── Formatters ────────────────────────────────────────────────────
def fsec(x):
    try: x = float(x)
    except: return '—'
    if x != x: return '—'   # NaN
    if x < 1e-3:  return f"{x*1e6:.0f}µs"
    if x < 1:     return f"{x*1e3:.1f}ms"
    return f"{x:.3f}s"

def fstddev(x):
    try: x = float(x)
    except: return '—'
    if x < 1e-3:  return f"±{x*1e6:.0f}µs"
    if x < 1:     return f"±{x*1e3:.1f}ms"
    return f"±{x:.3f}s"

def fratio(v, best, higher_better=False):
    if v is None or best is None or best == 0:
        return '—'
    r = (v / best) if not higher_better else (best / v)
    if r < 1.005:        return GRN('1x')
    s = f"{r:.2f}x"
    if r < 1.5:          return s
    if r < 2.0:          return YEL(s)
    return RED(s)

# ── Sysinfo section ───────────────────────────────────────────────
sysinfo = [r for r in rows if r['bench'] == 'sysinfo']
if sysinfo:
    section('System Info')
    hdr = ['HOST', 'OS/ARCH', 'CPUS', 'MEMORY', 'GPU', 'NIX']
    data = []
    for r in sysinfo:
        m = r['m']
        data.append([
            r['host'],
            f"{m.get('os', '?')}/{m.get('arch', '?')}",
            m.get('cpus', '?'),
            m.get('mem', '?'),
            (m.get('gpu', 'none') or 'none').replace('_', ' ')[:55],
            m.get('nix', '?'),
        ])
    widths = [max(vlen(row[i]) for row in [hdr] + data) for i in range(len(hdr))]
    print('  ' + '  '.join(DIM(pad(h, w)) for h, w in zip(hdr, widths)))
    for row in data:
        print('  ' + '  '.join(pad(v, w) for v, w in zip(row, widths)))

# ── Timing section (median/p95, lower is better) ──────────────────
timing_benches = [b for b in benches
                  if b != 'sysinfo'
                  and any(r['bench'] == b and r['status'] == 'ok'
                          and 'seconds' in r['m'] and 'write_MBs' not in r['m']
                          for r in rows)]

if timing_benches:
    section('Timing', 'median / p95 — lower is better')
    hdr  = ['BENCHMARK',   'HOST',   'MEDIAN', 'P95',    'MIN',    'MAX',    'STDDEV', 'RUNS', 'VS BEST']
    rights=[False,         False,     True,     True,     True,     True,     True,     True,   False]
    tbl = [hdr]
    for bench in timing_benches:
        entries = [r for r in rows if r['bench'] == bench]
        ok_secs = [float(r['m']['seconds']) for r in entries if r['status'] == 'ok']
        best = min(ok_secs) if ok_secs else None
        for i, r in enumerate(entries):
            m = r['m']
            first = bench if i == 0 else ''
            if r['status'] != 'ok':
                tbl.append([first, r['host'], RED('FAIL'), '—', '—', '—', '—', '—', RED('—')])
                continue
            sec = float(m.get('seconds', 'nan'))
            cells = [
                first,
                r['host'],
                (GRN(fsec(sec)) if best is not None and abs(sec - best) < 1e-9 else fsec(sec)),
                fsec(m.get('p95', 'nan')),
                fsec(m.get('min', 'nan')),
                fsec(m.get('max', 'nan')),
                fstddev(m.get('stddev', 'nan')) if 'stddev' in m else '—',
                m.get('runs', '—'),
                fratio(sec, best),
            ]
            tbl.append(cells)
    widths = [max(vlen(row[i]) for row in tbl) for i in range(len(hdr))]
    for ri, row in enumerate(tbl):
        cells = []
        for v, w, right in zip(row, widths, rights):
            cells.append(pad(DIM(v) if ri == 0 else v, w, right=right))
        print('  ' + '  '.join(cells))

# ── Throughput section (disk_seq, disk_rand) ──────────────────────
disk = [r for r in rows if r['bench'] in ('disk_seq', 'disk_rand')]
if any(r['status'] == 'ok' for r in disk):
    section('Disk throughput', 'larger is better')
    hdr  = ['BENCHMARK', 'HOST',   'TIME',   'WRITE',      'READ',       'VS BEST (write)']
    rights=[False,       False,     True,     True,         True,         False]
    tbl = [hdr]
    for bench in ['disk_seq', 'disk_rand']:
        entries = [r for r in rows if r['bench'] == bench]
        if not entries: continue
        key_w = 'write_MBs' if bench == 'disk_seq' else 'write_iops'
        key_r = 'read_MBs'  if bench == 'disk_seq' else 'read_iops'
        unit  = 'MB/s' if bench == 'disk_seq' else 'IOPS'
        ok_w = [float(r['m'].get(key_w, 0)) for r in entries if r['status'] == 'ok' and key_w in r['m']]
        best = max(ok_w) if ok_w else None
        for i, r in enumerate(entries):
            m = r['m']
            first = bench if i == 0 else ''
            if r['status'] != 'ok':
                tbl.append([first, r['host'], RED('FAIL'), '—', '—', RED('—')])
                continue
            w = float(m.get(key_w, 'nan'))
            rd = float(m.get(key_r, 'nan'))
            cells = [
                first,
                r['host'],
                fsec(m.get('seconds', 'nan')),
                (GRN(f"{w:.1f} {unit}") if best is not None and abs(w - best) < 1e-6
                 else f"{w:.1f} {unit}"),
                f"{rd:.1f} {unit}",
                fratio(w, best, higher_better=True),
            ]
            tbl.append(cells)
    widths = [max(vlen(row[i]) for row in tbl) for i in range(len(hdr))]
    for ri, row in enumerate(tbl):
        cells = []
        for v, w, right in zip(row, widths, rights):
            cells.append(pad(DIM(v) if ri == 0 else v, w, right=right))
        print('  ' + '  '.join(cells))

# ── Failures ──────────────────────────────────────────────────────
fails = [r for r in rows if r['status'] != 'ok']
if fails:
    section('Failures')
    grouped = OrderedDict()
    for r in fails:
        grouped.setdefault(r['bench'], []).append(r['host'])
    bw = max(len(b) for b in grouped) + 2
    for bench, hs in grouped.items():
        hosts_str = ', '.join(hs)
        print(f"  {pad(RED(bench), bw)}  {len(hs)} host(s): {hosts_str}")
    print(f"  {DIM('(see per-host logs in ' + results_dir + ')')}")

print()
PYEOF

echo "Per-host logs: $RESULTS_DIR/<label>.log"
echo "TSV:           $TSV"
