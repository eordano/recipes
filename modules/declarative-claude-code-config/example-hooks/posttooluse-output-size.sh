#!/usr/bin/env bash
set -euo pipefail
INPUT=$(cat)

STDOUT=$(printf '%s' "$INPUT" | jq -r '.tool_result.stdout // empty')
STDERR=$(printf '%s' "$INPUT" | jq -r '.tool_result.stderr // empty')
TOTAL_LEN=$((${#STDOUT} + ${#STDERR}))

if [ "$TOTAL_LEN" -gt 10000 ]; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // "unknown"')
  cat >&2 <<MSG
Warning: that command produced ${TOTAL_LEN} chars of output — a lot of tokens.
Next time redirect to a file and read a slice:
  ${COMMAND} > /tmp/out.log 2>&1; tail -n 30 /tmp/out.log
MSG
fi

exit 0
