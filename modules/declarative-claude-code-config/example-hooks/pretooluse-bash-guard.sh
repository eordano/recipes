#!/usr/bin/env bash
set -euo pipefail
INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')

if printf '%s' "$COMMAND" | grep -qE '/nix/store/[a-z0-9]{32}-'; then
  cat >&2 <<'MSG'
Warning: hardcoded /nix/store path detected. These go stale after a rebuild.
Prefer `$(nix build .#pkg --print-out-paths)/bin/foo`.
MSG
  exit 0
fi

if printf '%s' "$COMMAND" | grep -qE '\btail\s+-[0-9]*f\b'; then
  cat >&2 <<'MSG'
Blocked: don't use `tail -f` — it never returns and streams unlimited output.
Use `tail -n 20 /path/to/file` for a fixed snapshot instead.
MSG
  exit 2
fi

exit 0
