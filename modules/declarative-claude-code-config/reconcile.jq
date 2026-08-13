# Idempotent reconciler for a mutable JSON app config.
#
# Inputs (all via --argjson):
#   $defaults  object deep-merged UNDER the live file  (live keys win)
#   $enforce   object deep-merged OVER  the live file  (these keys always win)
#   $forbid    array of key paths (jq `delpaths` form) stripped when present
#   $required  object of PreToolUse/PostToolUse-style hook groups to ensure
#              (Claude Code settings.json shape); pass {} to skip entirely
#   $existing  array of filenames present in the hooks dir, used to prune
#              references to hooks that no longer exist on disk
#
# The input is the parsed live config; the output is the reconciled config.
# Running it twice in a row is a no-op — that is what makes it safe to run on
# every activation without ever clobbering keys the user or the app wrote.

def reconcile:
  # defaults seed where absent, enforce overrides always, forbid deletes.
  (($defaults * .) * $enforce)
  | delpaths($forbid)
  # Optional: ensure a set of required hook entries exists, without duplicating
  # ones already present and without disturbing user-added sibling entries.
  | if ($required | length) > 0 then
      reduce ($required | keys[]) as $phase (.;
        .hooks[$phase] //= []
        | reduce ($required[$phase][]) as $rgroup (.;
            ($rgroup.matcher) as $m
            | if (.hooks[$phase] | map(select(.matcher == $m)) | length) == 0 then
                .hooks[$phase] += [$rgroup]
              else
                reduce ($rgroup.hooks[]) as $rhook (.;
                  if (.hooks[$phase][] | select(.matcher == $m) | .hooks
                        | map(select(.command == $rhook.command)) | length) == 0 then
                    (.hooks[$phase][] | select(.matcher == $m) | .hooks) += [$rhook]
                  else . end
                )
              end
          )
      )
      # Prune stale entries: keep a hook command only if it is one we declare,
      # or it points at a file that still exists in the hooks dir, or it is not
      # a hooks-dir path at all (leave unrelated user commands untouched).
      | ([$required[][].hooks[].command]) as $declared
      | .hooks |= with_entries(
          .value |= (
            map(
              .hooks |= ((. // []) | map(
                (.command // "") as $c
                | select(
                    if ($declared | index($c)) != null then true
                    elif ($c | test("/hooks/[^/ ]+$")) then
                      any($existing[]; . == ($c | sub("^.*/hooks/"; "")))
                    else true end
                  )
              ))
            )
            | map(select((.hooks | length) > 0))
          )
        )
      | .hooks |= with_entries(select((.value | length) > 0))
    else . end;

reconcile
