#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

if [ -n "${LEAK_GUARD_PATTERN:-}" ]; then
  PAT=$LEAK_GUARD_PATTERN
elif [ -f .leak-guard-pattern ]; then
  PAT=$(head -1 .leak-guard-pattern)
else
  PAT='a^'
  echo "leak-guard: WARNING -- private marker scan disabled; set LEAK_GUARD_PATTERN or create .leak-guard-pattern." >&2
fi

scan() { grep -rInE "$1" --exclude-dir=.git --exclude=.leak-guard-pattern . 2>/dev/null; }

SELF='([A-Za-z0-9_-]+\.github\.io/recipes|github(\.com)?[:/][A-Za-z0-9_-]+/recipes|repo_name: *[A-Za-z0-9_-]+/recipes|[[:space:]][A-Za-z0-9_-]+/recipes$)'
scan_markers() {
  scan "$PAT" | while IFS= read -r line; do
    if printf '%s' "$line" | sed -E "s#$SELF##g" | grep -qE "$PAT"; then
      printf '%s\n' "$line"
    fi
  done
}

ip=$(scan "100\.64\.[0-9]+\.[0-9]+" | grep -vE "100\.64\.[0-9]+\.[0-9]+/[0-9]+")
ip6=$(scan "fd7a:115c:a1e0:[0-9a-fA-F:]*[0-9a-fA-F]" |
  grep -vE "fd7a:115c:a1e0:[0-9a-fA-F:]*[0-9a-fA-F]/[0-9]+")
named=$(scan_markers)

checkout=$(scan "(^|[^A-Za-z0-9_-])/[A-Za-z0-9_./-]*(nixpkgs|nixos-config)(/|$|[^A-Za-z0-9_.-])")
homedir=$(scan "(/home/|/Users/)[A-Za-z0-9_.-]+" |
  grep -vE "/(home|Users)/(alice|bob|carol|dave|user|users|youruser|me|dev|node|example)([^A-Za-z0-9_.-]|$)")

hits="$ip
$ip6
$named
$checkout
$homedir"
hits=$(echo "$hits" | grep -vE '^\s*$')
if [ -n "$hits" ]; then
  echo "LEAK-GUARD FAIL:"
  echo "$hits"
  exit 1
fi
echo "leak-guard: CLEAN"
