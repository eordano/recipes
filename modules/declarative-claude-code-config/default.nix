{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.claudeCodeConfig;
  json = builtins.toJSON;

  reconciler = pkgs.writeShellScript "reconcile-json-config" ''
    set -euo pipefail
    JQ=${pkgs.jq}/bin/jq

    ENFORCE=${lib.escapeShellArg (json cfg.settings.enforce)}
    DEFAULTS=${lib.escapeShellArg (json cfg.settings.defaults)}
    FORBID=${lib.escapeShellArg (json cfg.settings.forbid)}
    REQUIRED=${lib.escapeShellArg (json cfg.requiredHooks)}
    HOOKS_DIR=${lib.escapeShellArg cfg.hooksDir}

    # Filenames currently present in the hooks dir, so the reconciler can drop
    # references to hooks that were removed from the declaration.
    EXISTING=$( (cd "$HOOKS_DIR" 2>/dev/null && ls -1 || true) | $JQ -R . | $JQ -s . )

    reconcile_file() {
      local f="$1"
      mkdir -p "$(dirname "$f")"
      [ -f "$f" ] || echo '{}' > "$f"

      local tmp
      tmp=$(mktemp)
      $JQ \
        --argjson enforce  "$ENFORCE" \
        --argjson defaults "$DEFAULTS" \
        --argjson forbid   "$FORBID" \
        --argjson required "$REQUIRED" \
        --argjson existing "$EXISTING" \
        -f ${./reconcile.jq} "$f" > "$tmp"

      # Only replace the file when something actually changed, so we neither
      # bump its mtime needlessly nor race the app for no reason.
      if ! diff -q "$f" "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$f"
        echo "Reconciled $f against the declared policy."
      else
        rm -f "$tmp"
        echo "$f already matches policy."
      fi
    }

    ${lib.concatMapStringsSep "\n    " (t: "reconcile_file ${lib.escapeShellArg t}") cfg.targets}
  '';

  exampleHookFiles = {
    "pretooluse-bash-guard.sh" = ./example-hooks/pretooluse-bash-guard.sh;
    "posttooluse-output-size.sh" = ./example-hooks/posttooluse-output-size.sh;
  };
  exampleRequiredHooks = {
    PreToolUse = [
      {
        matcher = "Bash";
        hooks = [
          {
            type = "command";
            command = "${cfg.hooksDir}/pretooluse-bash-guard.sh";
          }
        ];
      }
    ];
    PostToolUse = [
      {
        matcher = "Bash";
        hooks = [
          {
            type = "command";
            command = "${cfg.hooksDir}/posttooluse-output-size.sh";
          }
        ];
      }
    ];
  };
in
{
  options.programs.claudeCodeConfig = {
    enable = lib.mkEnableOption "declarative reconciliation of a mutable JSON app config";

    targets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "${config.home.homeDirectory}/.claude/settings.json" ];
      defaultText = lib.literalExpression ''[ "''${config.home.homeDirectory}/.claude/settings.json" ]'';
      example = lib.literalExpression ''
        [
          "''${config.home.homeDirectory}/.claude/settings.json"
          "''${config.xdg.configHome}/claude/settings.json"
        ]
      '';
      description = ''
        Absolute paths of the JSON files to reconcile. Each is created as `{}`
        if missing, then the same policy is applied to all of them. These are
        real, editable files -- never store symlinks.
      '';
    };

    hooksDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.claude/hooks";
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/.claude/hooks"'';
      description = ''
        Directory that hook command paths point at. Used to prune settings
        entries whose script no longer exists on disk.
      '';
    };

    settings = {
      enforce = lib.mkOption {
        type = lib.types.attrs;
        default = {
          env.DISABLE_AUTOUPDATER = "1";
        };
        description = ''
          Deep-merged OVER the live file on every activation -- these values
          always win, so drift is corrected, while sibling keys the user (or the
          app) wrote survive untouched.
        '';
      };
      defaults = lib.mkOption {
        type = lib.types.attrs;
        default = {
          theme = "dark";
          model = "opus";
        };
        description = ''
          Seeded (deep) into the file only where the key is absent. Once
          present, later live edits win on every reconciliation.
        '';
      };
      forbid = lib.mkOption {
        type = lib.types.listOf (lib.types.listOf lib.types.str);
        default = [ ];
        example = [
          [
            "env"
            "ANTHROPIC_API_KEY"
          ]
        ];
        description = ''
          Key paths (jq `delpaths` form) removed from the file whenever they
          reappear -- e.g. to keep a secret from being persisted into a
          world-readable config.
        '';
      };
    };

    requiredHooks = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = ''
        Claude Code `hooks`-shaped object of PreToolUse/PostToolUse groups to
        ensure exist. Entries are added idempotently (no duplicates) and
        user-added sibling entries are left alone. Leave `{}` to manage only the
        enforce/defaults/forbid surface.
      '';
    };

    installExampleHooks = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install two generic example guardrail hooks (a PreToolUse Bash guard and
        a PostToolUse output-size warning) into `hooksDir`, and add their
        entries to `requiredHooks`. Off by default so the module carries no
        opinion about your guardrails.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        home.activation.reconcileJsonConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          run ${reconciler}
        '';
      }
      (lib.mkIf cfg.installExampleHooks {
        programs.claudeCodeConfig.requiredHooks = exampleRequiredHooks;

        home.file = lib.mapAttrs' (
          name: src:
          lib.nameValuePair ".claude/hooks/${name}" {
            source = src;
            executable = true;
          }
        ) exampleHookFiles;
      })
    ]
  );
}
