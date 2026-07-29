#!/usr/bin/env bash
# Fail if any private marker leaked into the recipe tree. The actual patterns
# live in an UNTRACKED .leak-guard-pattern file (one extended regex on line 1)
# so the guard itself never discloses what it guards. Flag SPECIFIC host
# addresses/names, not shared ranges like CGNAT (100.64.0.0/10) or the
# Tailscale ULA (fd7a:115c:a1e0::/48), which are generic public knowledge.
#
# .leak-guard-pattern example:
#   mycorp\.example|\b(hostname1|hostname2)\b|age1yourmasterrecipient...
#
# SCOPE: everything in the repo except .git and the pattern file itself.
# Prose leaks as easily as code — the first operator-local path found here was
# in a README, which an earlier code-directories-only scan never looked at.
set -uo pipefail
cd "$(dirname "$0")"

# CI can provide the private marker regex through a repository secret without
# writing or committing it. Generic address and path checks always run, so a
# fresh public fork remains buildable even when no private marker is configured.
if [ -n "${LEAK_GUARD_PATTERN:-}" ]; then
    PAT=$LEAK_GUARD_PATTERN
elif [ -f .leak-guard-pattern ]; then
    PAT=$(head -1 .leak-guard-pattern)
else
    PAT='a^'
    echo "leak-guard: WARNING — private marker scan disabled; set LEAK_GUARD_PATTERN or create .leak-guard-pattern." >&2
fi

scan() { grep -rInE "$1" --exclude-dir=.git --exclude=.leak-guard-pattern . 2>/dev/null; }

# This project's own publication coordinates. They necessarily name the account
# that publishes the repo, which a marker pattern will match — but they are the
# public identity of this very repo, not a leak. Written generically so the
# guard still discloses nothing. Matches are stripped from a line before the
# marker test, so a real marker sharing a line with a self-reference still trips.
# The account component is matched without dots on purpose: a private forge
# would appear as host.domain.tld/recipes, which must NOT be stripped.
SELF='([A-Za-z0-9_-]+\.github\.io/recipes|github(\.com)?[:/][A-Za-z0-9_-]+/recipes|repo_name: *[A-Za-z0-9_-]+/recipes|[[:space:]][A-Za-z0-9_-]+/recipes$)'
scan_markers() {
    scan "$PAT" | while IFS= read -r line; do
        if printf '%s' "$line" | sed -E "s#$SELF##g" | grep -qE "$PAT"; then
            printf '%s\n' "$line"
        fi
    done
}

# Specific CGNAT/ULA host addresses only — never CIDR ranges (any "/NN"
# suffix) or the bare Tailscale ULA range declaration itself, both of
# which are generic public knowledge, not leaks.
ip=$(scan "100\.64\.[0-9]+\.[0-9]+" | grep -vE "100\.64\.[0-9]+\.[0-9]+/[0-9]+")
ip6=$(scan "fd7a:115c:a1e0:[0-9a-fA-F:]*[0-9a-fA-F]" \
    | grep -vE "fd7a:115c:a1e0:[0-9a-fA-F:]*[0-9a-fA-F]/[0-9]+")
named=$(scan_markers)

# Operator-local filesystem paths. Published recipes must cite upstream by
# repo-relative path (pkgs/…/default.nix), never by where a checkout happens to
# sit on the author's machine. Documentation placeholders are allowed so
# examples can still show a home directory.
checkout=$(scan "(^|[^A-Za-z0-9_-])/[A-Za-z0-9_./-]*(nixpkgs|nixos-config)(/|$|[^A-Za-z0-9_.-])")
homedir=$(scan "(/home/|/Users/)[A-Za-z0-9_.-]+" \
    | grep -vE "/(home|Users)/(alice|bob|carol|dave|user|users|youruser|me|dev|node|example)([^A-Za-z0-9_.-]|$)")

hits="$ip
$ip6
$named
$checkout
$homedir"
hits=$(echo "$hits" | grep -vE '^\s*$')
if [ -n "$hits" ]; then echo "LEAK-GUARD FAIL:"; echo "$hits"; exit 1; fi
echo "leak-guard: CLEAN"
