# network-isolated-editor

Wrap your `$EDITOR` — or any interactive program — in a **no-network sandbox**,
as a NixOS / nix-darwin module. The editor runs with loopback only: no outbound,
no allowlist, no proxy. Plugins that phone home simply can't.

## The problem

An editor is a big pile of third-party plugins running with your credentials on
your working tree. LSP servers, package managers, "AI" plugins, telemetry —
plenty of code you didn't audit gets to open sockets. A cheap, total mitigation
is to give the editor a network namespace with nothing in it but loopback. On
Linux that's `bwrap --unshare-net`; on macOS it's `sandbox-exec` with
`(deny network*)`.

The naive version of this works right up until it wrecks your `git commit`. This
recipe exists because of two traps that only show up in production.

## Trap 1 — use bubblewrap, not firejail

firejail runs the sandboxed process inside a **PID namespace**. The namespace's
monitor (PID 1) refuses to exit until *every* process in the namespace is gone.

Editors spawn background job children — LSP servers, treesitter parsers,
formatters. On `:wq` the editor exits, but those children **linger** for a beat.
firejail keeps waiting for them, so any caller doing an `$EDITOR` handoff — `git
commit`, `git rebase -i`, `crontab -e`, `visudo` — hangs **forever** at:

```
hint: Waiting for your editor to close the file...
```

The nasty part: closing the file *without editing* never spawns a job child, so
it exits cleanly and the bug looks like it isn't there. It only bites once you
actually touch a buffer that triggers an LSP.

**bwrap creates no PID namespace.** It waits only on the editor process itself;
lingering job children reparent to `init` and nobody blocks. Same net isolation
(`--unshare-net`), none of the hang. That's the whole reason this recipe uses
bubblewrap on Linux.

## Trap 2 — no-op under an agent sandbox

Agent runtimes (coding assistants and similar tools that launch an editor for
you) export `IS_SANDBOX=1` and **already govern the network** for everything
they spawn. Nesting a second sandbox inside that one breaks the `$EDITOR`
handoff.

So the wrapper checks `IS_SANDBOX` first and, if set, just `exec`s the editor
directly — letting the outer sandbox do its job. You get isolation from a normal
shell and correct behavior inside an agent, with no configuration.

## Usage

Import `default.nix` as a module and enable it:

```nix
{ pkgs, ... }:
{
  imports = [ ./network-isolated-editor ];

  programs.networkIsolatedEditor = {
    enable  = true;
    package = pkgs.neovim;   # any editor derivation
    binName = "nvim";        # the binary inside `package`
    aliases = [ "vim" ];     # extra names symlinked to the wrapper
  };
}
```

The module installs a `hiPrio` wrapper into `environment.systemPackages`, so it
shadows the unwrapped editor on `PATH`. Point `EDITOR=nvim` (or `vim`) as usual.

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Install the wrapper. |
| `package` | `pkgs.neovim` | Editor derivation to wrap. |
| `binName` | `"nvim"` | Binary name inside `package`; also the wrapper's name. |
| `aliases` | `[ ]` | Extra command names symlinked to the wrapper (e.g. `[ "vim" ]`). |
| `networkIsolation` | `true` | Turn the sandbox off to install just the prelude + aliases. |
| `extraPrelude` | `""` | Shell run before the editor in every mode — extra env / PATH. |
| `writePaths` | editor state dirs | **macOS only.** Extra subpaths the sandboxed editor may write to. |

### `extraPrelude`

Anything you'd otherwise put in a launcher wrapper — an extra env var, a
`NIX_PATH` tweak so `gd` jumps into a checkout, a `PATH` prepend — goes here as
raw shell. It runs in all three modes (isolated, agent-sandbox no-op, plain), so
the environment is identical however the editor ends up launched:

```nix
programs.networkIsolatedEditor.extraPrelude = ''
  export NIX_PATH="nixpkgs=$HOME/nixpkgs''${NIX_PATH:+:$NIX_PATH}"
'';
```

## Caveats

- **No network means no network.** LSP installers, plugin managers that fetch on
  startup, remote-fetching AI plugins — none of it works inside the wrapper.
  That's the point. When you genuinely need outbound, relaunch the editor from
  outside the wrapper (e.g. call the unwrapped `${package}/bin/${binName}`
  directly, or flip `networkIsolation = false` for that host). This recipe is
  deliberately all-or-nothing; there is no allowlist or CONNECT proxy here.

- **Linux binds the whole host filesystem** (`--bind / /`) read-write — the
  sandbox is about the *network*, not the filesystem. If you also want write
  confinement on Linux, add `--ro-bind` / `--bind` scoping to the bwrap
  invocation.

- **macOS write confinement is opt-in via `writePaths`.** The macOS profile is
  `(allow default)` minus network minus writes outside an allowlist (the working
  tree, tmp, `/dev`, and `writePaths`). Set `writePaths` to your editor's own
  state / cache / config directories, or it won't be able to persist anything.
  Defaults target Neovim's XDG dirs; change them for a different editor.

- **macOS profile safety.** The working tree (`$CWD`) and `$TMPDIR` are runtime
  values that can contain arbitrary characters — an adopter may `cd` into a
  directory whose attacker-chosen name embeds `"` / `(` / `)`. Those values are
  therefore **never** spliced into the sandbox policy text (which would let a
  crafted name close a `(subpath "…")` form early and inject its own rules,
  e.g. `(allow network*)`, defeating the whole point). They are passed to
  `sandbox-exec` via `-D` and referenced with `(param …)`, so they are treated
  as opaque data, not policy. Only the module-author-controlled `writePaths`
  allowlist is interpolated into the profile.

- Requires `pkgs.bubblewrap` on Linux and `/usr/bin/sandbox-exec` on macOS (ships
  with the OS; deprecated by Apple but still present and functional).
