# home-manager-alias-namespace

A thin, top-level `home.*` namespace that any NixOS module can contribute to,
forwarded into one or more Home Manager users — so modules never have to know
*which* user owns the Home Manager config.

## The problem

Home Manager config lives under `home-manager.users.<name>.…`. That name is a
per-host detail: the login user might be `alice` on one machine and `bob` on
another, and a single machine may run HM for several users at once. If every
module that wants to drop a dotfile has to spell out the username, you either
hardcode it everywhere (and break on the next host) or thread the username
through as an argument (and pollute every module signature).

## The insight

Declare a **host-neutral top-level namespace** — `home.file`, `home.activation`,
`home.env`, `home.programs`, `home.services` — that modules write to freely:

```nix
home.file.".config/foo".text = "hello";
home.activation.greet.text = "echo hi";
```

Then alias those definitions into each real Home Manager user with
`lib.mkAliasDefinitions`:

```nix
home-manager.users.<name>.home.file =
  lib.mkAliasDefinitions options.home.file;
```

`mkAliasDefinitions` forwards the *definitions* of one option onto another,
preserving each contributor's priority (`mkForce`, `mkDefault`, `mkIf`, …)
instead of collapsing everything to a single merged value. That means N modules
can each add to `home.file` and their overrides still resolve correctly on the
far side. The username is decided in exactly one place (this module's
`users` option); everything else stays generic.

Using `lib.genAttrs users mkUser`, the *same* aliased definitions land in every
managed user, so one `home.file.…` set anywhere applies to all of them.

## What else it bundles

Two small conveniences that pair naturally with a workstation HM setup, both
individually toggleable:

- **Nightly `nix-index` rebuild.** Keeps the `nix-locate` /
  command-not-found database fresh. It runs as a `oneshot` at `Nice 19` with
  `IOSchedulingClass = idle`, so it never competes with foreground work, and
  the timer is `Persistent` with a 30-minute `RandomizedDelaySec` so a machine
  that was off at the scheduled time still catches up (and a fleet doesn't all
  fire at once).

- **XDG user-dirs archive redirect.** Points Desktop / Downloads / Pictures /
  Videos into an `archive/` subtree to keep `$HOME` uncluttered, while
  Documents / Music / Templates collapse back to `$HOME`.

## Traps worth knowing

- **`user-dirs.conf` with `enabled=False`.** Without it, the
  `xdg-user-dirs-update` daemon rewrites your carefully redirected paths back to
  defaults on the next login. This line disables that daemon so the declarative
  paths stick.

- **`createDirectories = false`.** HM would otherwise materialise empty
  `Desktop/`, `Templates/`, etc. that you never asked for.

- **`nix-index` needs `HOME` set.** The rebuild writes
  `~/.cache/nix-index/files`; a systemd service has no `HOME` unless you set
  one, so the `nixIndex.home` option feeds it explicitly (defaults to
  `/home/<user>`).

- **`nix-index` wants the network.** The rebuild fetches store metadata, hence
  the `network-online.target` ordering. On an offline box the timer simply
  fails and retries next cycle.

- **This module does not import home-manager.** It assumes the Home Manager
  NixOS module is already imported by your configuration (via its flake input or
  channel). It only *populates* `home-manager.users`.

## Usage

Import `default.nix`, enable it, and name your users:

```nix
{
  imports = [ ./home-manager-alias-namespace ];

  enable-home-manager = true;

  home-manager-alias = {
    users = [ "alice" ];       # who receives the aliased home.* namespace
    enableLorri = true;         # optional: services.lorri.enable per user
    xdg.enable = true;          # optional: archive/ user-dirs redirect
    xdg.archiveRoot = "$HOME/archive";
    nixIndex.enable = true;     # optional: nightly nix-index rebuild
    sharedModules = [ ];        # optional: extra HM modules for every user
  };

  # ...and now, from ANY module:
  home.file.".config/foo".text = "…";
}
```

### Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable-home-manager` | `false` | Master switch for the whole module. |
| `home.{file,activation,env,programs,services}` | `{}` | The namespace modules write to. `env` aliases to `home.sessionVariables`. |
| `home-manager-alias.users` | `[ "user" ]` | Users that receive the aliased namespace. |
| `home-manager-alias.enableLorri` | `false` | Turn on `services.lorri` per user. |
| `home-manager-alias.xdg.enable` | `true` | Redirect XDG user-dirs into an archive subtree. |
| `home-manager-alias.xdg.archiveRoot` | `"$HOME/archive"` | Base dir for the archived XDG dirs. |
| `home-manager-alias.sharedModules` | `[ ]` | HM modules applied to every managed user. |
| `home-manager-alias.nixIndex.enable` | `true` | Nightly `nix-index` rebuild timer. |
| `home-manager-alias.nixIndex.user` | first of `users` | User the rebuild runs as. |
| `home-manager-alias.nixIndex.home` | `/home/<user>` | `HOME` for the rebuild service. |
| `home-manager-alias.nixIndex.nixPath` | `null` | Optional `NIX_PATH` override. |

## Caveats

- The `home.programs` / `home.services` namespaces are intentionally loose
  (untyped attrs) so any module can contribute without importing this file. That
  means typos in contributed attribute names surface as Home Manager errors, not
  option errors — the tradeoff for decoupling.
- `man.generateCaches = false` and `ssh.enableDefaultConfig = false` are set on
  every managed user to avoid slow man-cache builds and HM's opinionated default
  SSH config. Drop them from `mkUser` if you want HM's defaults.
