# declarative-claude-code-config

A Home Manager module that keeps a **mutable** JSON app config under
declarative control -- **without** turning it into a read-only `/nix/store`
symlink. Claude Code's `~/.claude/settings.json` is the worked example, but the
technique applies to any app that persists its own state into a JSON file at
runtime.

## The problem

The obvious way to manage a config file in Home Manager is
`home.file."...".text = ...` -- but that materialises a symlink into an
immutable store path. That is exactly wrong for a file the app itself writes to:
Claude Code (and plenty of other tools) persist their own state into
`settings.json` at runtime -- last-used model, onboarding flags, permission
grants, hook edits the user makes through the UI. Point that path at a store
symlink and one of two things happens: the app's writes fail, or it clobbers the
symlink and your "declarative" config silently stops being declarative.

So the file has **two writers** -- you (via Nix) and the app (and the user) at
runtime -- and neither can be allowed to own it outright. You still want a
guarantee that a chosen *slice* of the file is reproducible and can't drift.

## The approach

Don't own the file -- **reconcile** it. Keep it a normal, out-of-store file, and
on every `home-manager` activation run a jq pass that merges only your declared
policy into whatever is currently on disk. Policy has three axes:

- **`enforce`** -- deep-merged *over* the live file; these keys always win, so
  drift is corrected every activation, while sibling keys the user or app wrote
  survive untouched.
- **`defaults`** -- deep-merged *under* the live file; seeded only where a key is
  absent, after which live edits win.
- **`forbid`** -- key paths (jq `delpaths` form) stripped whenever they reappear,
  e.g. to stop a secret from being persisted into a world-readable config.

The jq itself lives in `reconcile.jq` and is written to be **idempotent** --
running it twice in a row is a no-op -- which is what makes it safe to fire on
every activation. The activation entry is ordered `entryAfter "writeBoundary"`
so it runs after Home Manager finishes linking its store-managed files, and it
only rewrites the target when the merge actually changed something.

On top of the enforce/defaults/forbid core, there is an optional idempotent
"ensure these hook entries exist" merge shaped for Claude Code's `hooks` block:
it adds each declared hook once, leaves user-added sibling hooks alone, and
prunes entries whose script has been removed from `hooksDir`. Two genericized
example guardrail hooks ship under `example-hooks/` (a PreToolUse Bash guard and
a PostToolUse output-size warning) and can be installed with
`installExampleHooks = true`.

Those examples also double as a reference for Claude Code's hook contract, which
is the non-obvious part of writing one: a hook is fed a JSON blob on stdin (the
command under `tool_input.command` for a PreToolUse hook, captured output under
`tool_result.stdout` / `.stderr` for a PostToolUse hook), and its **exit code**
is the control channel. From a PreToolUse hook, exit 2 blocks the tool call and
feeds the hook's stderr back to the model, while exit 0 -- even with text on
stderr -- is a non-blocking warning. That is why the guards deliberately choose
between the two rather than always failing.

## Usage

```nix
{
  imports = [ ./declarative-claude-code-config ];

  programs.claudeCodeConfig = {
    enable = true;

    # Reconcile both the home and XDG copies with one policy.
    targets = [
      "${config.home.homeDirectory}/.claude/settings.json"
      "${config.xdg.configHome}/claude/settings.json"
    ];

    settings.enforce = { env.DISABLE_AUTOUPDATER = "1"; };
    settings.defaults = { theme = "dark"; model = "opus"; };
    settings.forbid = [ [ "env" "ANTHROPIC_API_KEY" ] ];

    installExampleHooks = true;   # optional guardrail hooks
  };
}
```

### Options

| Option | Default | Purpose |
| --- | --- | --- |
| `programs.claudeCodeConfig.enable` | `false` | Master switch. |
| `.targets` | `[ "$HOME/.claude/settings.json" ]` | Absolute paths of JSON files to reconcile (created as `{}` if missing). |
| `.hooksDir` | `"$HOME/.claude/hooks"` | Hook-script dir; used to prune entries whose file is gone. |
| `.settings.enforce` | `{ env.DISABLE_AUTOUPDATER = "1"; }` | Keys merged *over* the live file (always win). |
| `.settings.defaults` | `{ theme = "dark"; model = "opus"; }` | Keys seeded only where absent. |
| `.settings.forbid` | `[ ]` | Key paths (jq `delpaths`) deleted whenever present. |
| `.requiredHooks` | `{ }` | Claude Code `hooks`-shaped groups to ensure idempotently. |
| `.installExampleHooks` | `false` | Install the two example hooks and wire their `requiredHooks` entries. |

## Traps (the reason this module exists)

- **A store symlink breaks a self-persisting app.** This is the whole point:
  the file must stay a real, writable file. If you ever "simplify" this to
  `home.file."...".text`, the app's own writes stop persisting (or fight the
  symlink) and the config silently de-declaratives. The out-of-store,
  activation-time jq merge is the price of letting both writers coexist.
- **The merge must be idempotent, or activation churns the file.** Because it
  runs on *every* activation over live state, a non-idempotent filter would keep
  rewriting the file (bumping its mtime, re-triggering watchers, and possibly
  racing the app). `reconcile.jq` is written so a second pass is a no-op, and the
  script only `mv`s the result in when `diff` says it changed.
- **`enforce` vs `defaults` is a one-way door per key.** A key in `enforce` can
  never be locally overridden -- that is the guarantee. A key in `defaults` is
  the app's/user's to change after first seed. Putting a key in the wrong bucket
  either freezes something the user expects to tweak, or lets something you
  meant to pin drift.
- **`forbid` fires on the merged result.** `defaults`/`enforce` are applied
  first, then `delpaths(forbid)`. Don't `enforce` a key you also `forbid` -- the
  forbid wins and you get churn (added then deleted every run).
- **Stale-hook pruning keys on `hooksDir`.** A hook entry pointing at
  `.../hooks/<file>` is dropped when `<file>` isn't in `hooksDir`. Commands that
  are not hooks-dir paths are left untouched. If you install hooks somewhere
  else, set `hooksDir` to match or valid entries get pruned.
- **Example hooks assume the default `hooksDir`.** With `installExampleHooks`,
  the scripts land in `~/.claude/hooks/`. If you also override `hooksDir` to a
  different location, install your own hooks there instead of relying on the
  bundled examples.
- **This module does not import home-manager.** It assumes Home Manager is
  already wired into your configuration; it only contributes an activation entry
  and (optionally) two hook files.
