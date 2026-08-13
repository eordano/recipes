{ pkgs }:
let
  lib = pkgs.lib;
  moduleText = builtins.readFile ./default.nix;
  _wired =
    assert lib.hasInfix "./reconcile.jq" moduleText;
    true;
  jq = "${pkgs.jq}/bin/jq";
  prog = ./reconcile.jq;
in
pkgs.runCommand "reconcile-json-config-test" { } ''
  set -euo pipefail
  reconcile() {
    ${jq} \
      --argjson enforce  "$1" \
      --argjson defaults "$2" \
      --argjson forbid   "$3" \
      --argjson required "$4" \
      --argjson existing "$5" \
      -f ${prog}
  }

  # 1. defaults seed where absent; live keys win; enforce overrides; forbid deletes.
  IN='{"model":"sonnet","env":{"ANTHROPIC_API_KEY":"secret","FOO":"1"}}'
  OUT=$(printf '%s' "$IN" | reconcile \
    '{"env":{"DISABLE_AUTOUPDATER":"1"}}' \
    '{"theme":"dark","model":"opus"}' \
    '[["env","ANTHROPIC_API_KEY"]]' \
    '{}' '[]')

  [ "$(printf '%s' "$OUT" | ${jq} -r '.theme')" = "dark" ]                 # default seeded
  [ "$(printf '%s' "$OUT" | ${jq} -r '.model')" = "sonnet" ]              # live wins over default
  [ "$(printf '%s' "$OUT" | ${jq} -r '.env.DISABLE_AUTOUPDATER')" = "1" ] # enforce wins
  [ "$(printf '%s' "$OUT" | ${jq} -r '.env.FOO')" = "1" ]                 # sibling survives
  [ "$(printf '%s' "$OUT" | ${jq} -r '.env.ANTHROPIC_API_KEY')" = "null" ] # forbidden removed

  # 2. running it again is a no-op (idempotent).
  OUT2=$(printf '%s' "$OUT" | reconcile \
    '{"env":{"DISABLE_AUTOUPDATER":"1"}}' \
    '{"theme":"dark","model":"opus"}' \
    '[["env","ANTHROPIC_API_KEY"]]' \
    '{}' '[]')
  [ "$OUT" = "$OUT2" ]

  # 3. required hooks are added once and only once, and survive re-running.
  REQ='{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/h/hooks/g.sh"}]}]}'
  H1=$(printf '{}' | reconcile '{}' '{}' '[]' "$REQ" '["g.sh"]')
  H2=$(printf '%s' "$H1" | reconcile '{}' '{}' '[]' "$REQ" '["g.sh"]')
  [ "$H1" = "$H2" ]
  [ "$(printf '%s' "$H1" | ${jq} '[.hooks.PreToolUse[0].hooks[] | select(.command=="/h/hooks/g.sh")] | length')" = "1" ]

  # 4. an entry whose hook file no longer exists is pruned (empty groups drop out).
  STALE='{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/h/hooks/gone.sh"}]}]}}'
  P=$(printf '%s' "$STALE" | reconcile '{}' '{}' '[]' "$REQ" '["g.sh"]')
  [ "$(printf '%s' "$P" | ${jq} '[.hooks.PreToolUse[]?.hooks[]? | select(.command=="/h/hooks/gone.sh")] | length')" = "0" ]

  echo "all reconcile.jq assertions passed" > "$out"
''
