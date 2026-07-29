# network-isolated-editor
#
# Wrap your $EDITOR (or any interactive program) in a no-network sandbox.
#
#   - Linux : bwrap --unshare-net  (a fresh net namespace with loopback only)
#   - macOS : sandbox-exec with (deny network*)
#
# Two hard-won traps are baked in (see README.md):
#
#   1. On Linux we deliberately use bubblewrap, NOT firejail. firejail runs the
#      editor inside a PID namespace whose monitor (PID 1) refuses to exit until
#      *every* process in the namespace is gone. Editors spawn LSP/treesitter
#      job children that linger past `:wq`, so firejail keeps waiting and any
#      caller doing an $EDITOR handoff (git commit, `crontab -e`, ...) hangs
#      forever at "Waiting for your editor to close the file...". bwrap creates
#      no PID namespace: it waits only on the editor, and lingering jobs
#      reparent to init.
#
#   2. The wrapper no-ops when IS_SANDBOX=1 is set. Agent runtimes (coding
#      assistants and similar) export IS_SANDBOX=1 and already govern the
#      network for everything they launch. Nesting a second sandbox inside that
#      one breaks the $EDITOR handoff, so we just exec the editor directly.
#
# This is a NixOS / nix-darwin module. Import it and set:
#
#   programs.networkIsolatedEditor = {
#     enable  = true;
#     package = pkgs.neovim;   # any editor derivation
#   };
#
# It installs a hiPrio wrapper named after `binName` (plus any `aliases`) into
# environment.systemPackages, shadowing the unwrapped editor on PATH.

{
  lib,
  pkgs,
  config,
  ...
}:

let
  cfg = config.programs.networkIsolatedEditor;

  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  # Wrap a derivation so `$out/bin/<name>` also appears under each alias name,
  # keeping the wrapped binary as the real entrypoint the alias points at.
  withAliases =
    drv:
    if cfg.aliases == [ ] then
      drv
    else
      pkgs.symlinkJoin {
        inherit (drv) name;
        paths = [ drv ];
        postBuild = lib.concatMapStringsSep "\n" (a: "ln -s ${cfg.binName} $out/bin/${a}") cfg.aliases;
      };

  # Any shell to run before exec'ing the editor (extra env, PATH tweaks, ...).
  # Kept generic on purpose — put your own `export FOO=bar` lines here.
  prelude = lib.optionalString (cfg.extraPrelude != "") (cfg.extraPrelude + "\n");

  # ---- Linux: bwrap --unshare-net -----------------------------------------
  mkLinuxWrapper =
    editor:
    withAliases (
      pkgs.writeShellScriptBin cfg.binName ''
        set -euo pipefail

        ${prelude}
        # Under an agent sandbox (IS_SANDBOX=1) the outer sandbox already
        # governs the network; nesting another one breaks the editor handoff.
        if [ -n "''${IS_SANDBOX:-}" ]; then
          exec ${editor}/bin/${cfg.binName} "$@"
        fi

        # Network isolation via bwrap --unshare-net: the net namespace gets
        # only loopback; everything else is a passthrough bind of the host.
        #
        # We deliberately do NOT use firejail: its PID-namespace monitor waits
        # for every process in the namespace to exit, and lingering LSP /
        # treesitter job children hang the $EDITOR handoff forever. bwrap
        # creates no PID namespace — it waits only on the editor, and stray
        # children reparent to init.
        exec ${pkgs.bubblewrap}/bin/bwrap \
          --unshare-net \
          --bind / / \
          --dev-bind /dev /dev \
          --proc /proc \
          --die-with-parent \
          ${editor}/bin/${cfg.binName} "$@"
      ''
    );

  # ---- macOS: sandbox-exec (deny network*) --------------------------------
  # sandbox-exec has no PID-namespace pitfall, but its default policy is
  # deny-nothing, so we allow-everything then subtract network + writes.
  # `writePaths` is an allowlist of subpaths the editor may still write to
  # (its own state/config/cache dirs, tmp, the working tree).
  darwinWriteAllow = lib.concatMapStringsSep "\n          " (p: ''(subpath "${p}")'') cfg.writePaths;

  mkDarwinWrapper =
    editor:
    withAliases (
      pkgs.writeShellScriptBin cfg.binName ''
        set -euo pipefail

        ${prelude}
        # See the Linux wrapper: skip the sandbox under an agent sandbox
        # (IS_SANDBOX=1) — nesting it breaks the $EDITOR handoff.
        if [ -n "''${IS_SANDBOX:-}" ]; then
          exec ${editor}/bin/${cfg.binName} "$@"
        fi

        TMPDIR="''${TMPDIR:-/tmp}"
        umask 077
        SANDBOX_FILE=$(mktemp "$TMPDIR/editor-sandbox.XXXXXX")
        trap 'rm -f "$SANDBOX_FILE"' EXIT

        CWD="$(pwd)"

        # The working tree ($CWD) and tmp ($TMPDIR) are runtime values that can
        # contain arbitrary characters (an adopter may `cd` into an
        # attacker-named directory). We MUST NOT splice them into the policy
        # text: a crafted name like  x") (allow network* ...) (subpath "  would
        # close the (subpath "...") form early and inject its own rules,
        # defeating the (deny network*) guarantee. Instead we pass them to
        # sandbox-exec via -D and reference them with (param ...), so they are
        # treated as opaque data, never as policy. The heredoc below therefore
        # contains no runtime-controlled values; the only interpolation is the
        # Nix-level, module-author-controlled ${"$"}{darwinWriteAllow} allowlist.
        cat > "$SANDBOX_FILE" << PROFILE
        (version 1)
        (allow default)

        ;; deny network*; allow loopback bind/listen + unix sockets.
        (deny network*)
        (allow network-outbound (remote unix-socket))
        (allow network-inbound (local unix-socket))
        (allow network-bind (local ip "localhost:*"))
        (allow network-inbound (local ip "localhost:*"))
        (allow network* (remote ip "localhost:*"))

        ;; deny writes outside the working tree, tmp, and the editor's own
        ;; state dirs. /dev is needed for libuv-style stdio.
        (deny file-write*
          (require-not
            (require-any
              (subpath (param "CWD"))
              (subpath (param "TMPDIR"))
              (subpath "/private/tmp")
              (subpath "/dev")
              (subpath "/private/var/folders")
              ${darwinWriteAllow})))
        PROFILE

        /usr/bin/sandbox-exec \
          -D CWD="$CWD" \
          -D TMPDIR="$TMPDIR" \
          -f "$SANDBOX_FILE" \
          ${editor}/bin/${cfg.binName} "$@"
      ''
    );

  # No isolation: just the editor, plus prelude and aliases.
  mkPlainWrapper =
    editor:
    withAliases (
      pkgs.writeShellScriptBin cfg.binName ''
        ${prelude}exec ${editor}/bin/${cfg.binName} "$@"
      ''
    );

  wrap =
    editor:
    if !cfg.networkIsolation then
      mkPlainWrapper editor
    else if isDarwin then
      mkDarwinWrapper editor
    else
      mkLinuxWrapper editor;

in
{
  options.programs.networkIsolatedEditor = {
    enable = lib.mkEnableOption "a network-isolated wrapper around an editor";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.neovim;
      defaultText = lib.literalExpression "pkgs.neovim";
      description = "The editor derivation to wrap. Its binary is `binName`.";
    };

    binName = lib.mkOption {
      type = lib.types.str;
      default = "nvim";
      description = ''
        The binary name inside `package` (i.e. `''${package}/bin/''${binName}`),
        and the name the wrapper is installed as.
      '';
    };

    aliases = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "vim" ];
      description = "Extra command names symlinked to the wrapper.";
    };

    networkIsolation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run the editor with no network access at all: `bwrap --unshare-net` on
        Linux, `sandbox-exec (deny network*)` on macOS. No allowlist, no proxy.
        Plugins that need outbound simply won't work inside the wrapper —
        relaunch the editor from outside it if you need the network. Set to
        false to install the editor with the prelude/aliases but no sandbox.
      '';
    };

    extraPrelude = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''export EDITOR_THEME=dark'';
      description = ''
        Shell run before the editor is exec'd, in every mode (isolated,
        agent-sandbox no-op, and plain). Use it for extra env or PATH setup.
      '';
    };

    writePaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "$HOME/.local/share/nvim"
        "$HOME/.local/state/nvim"
        "$HOME/.cache/nvim"
        "$HOME/.config/nvim"
      ];
      description = ''
        macOS only. Subpaths the sandboxed editor is still allowed to write to,
        on top of the working tree, tmp and /dev. Point these at your editor's
        own state / cache / config directories. Ignored on Linux, where bwrap
        binds the whole host filesystem read-write.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ (lib.hiPrio (wrap cfg.package)) ];
  };
}
