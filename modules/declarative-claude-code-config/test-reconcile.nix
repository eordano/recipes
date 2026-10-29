{ pkgs }:
let
  inherit (pkgs) lib;
  jq = "${pkgs.jq}/bin/jq";

  hmLib = lib.extend (
    _: _: {
      hm.dag.entryAfter = after: data: { inherit after data; };
    }
  );

  reconcilerFor =
    cfg:
    let
      evaluated = hmLib.evalModules {
        specialArgs = {
          inherit pkgs;
          lib = hmLib;
        };
        modules = [
          ./default.nix
          {
            options.home = {
              homeDirectory = lib.mkOption {
                type = lib.types.str;
                default = "/home/test";
              };
              activation = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              file = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
            };
            config.programs.claudeCodeConfig = {
              enable = true;
              targets = [ "settings.json" ];
              hooksDir = "hooks";
            }
            // cfg;
          }
        ];
      };
    in
    evaluated.config.home.activation.reconcileJsonConfig.data;

  policy = reconcilerFor {
    settings = {
      enforce.env.DISABLE_AUTOUPDATER = "1";
      defaults = {
        theme = "dark";
        model = "opus";
      };
      forbid = [
        [
          "env"
          "ANTHROPIC_API_KEY"
        ]
      ];
    };
  };

  hooks = reconcilerFor {
    settings = {
      enforce = { };
      defaults = { };
    };
    requiredHooks.PreToolUse = [
      {
        matcher = "Bash";
        hooks = [
          {
            type = "command";
            command = "/h/hooks/g.sh";
          }
        ];
      }
    ];
  };
in
pkgs.runCommand "reconcile-json-config-test" { } ''
  set -euo pipefail
  run() { "$@"; }
  mkdir work && cd work

  # 1. defaults seed where absent; live keys win; enforce overrides; forbid deletes.
  printf '%s' '{"model":"sonnet","env":{"ANTHROPIC_API_KEY":"secret","FOO":"1"}}' > settings.json
  ${policy}
  OUT=$(cat settings.json)
  [ "$(${jq} -r '.theme' settings.json)" = "dark" ]
  [ "$(${jq} -r '.model' settings.json)" = "sonnet" ]
  [ "$(${jq} -r '.env.DISABLE_AUTOUPDATER' settings.json)" = "1" ]
  [ "$(${jq} -r '.env.FOO' settings.json)" = "1" ]
  [ "$(${jq} -r '.env.ANTHROPIC_API_KEY' settings.json)" = "null" ]

  # 2. running it again is a no-op (idempotent).
  MSG=$(${policy})
  grep -q 'already matches policy' <<<"$MSG"
  [ "$(cat settings.json)" = "$OUT" ]

  # 3. required hooks are added once and only once, and survive re-running.
  mkdir hooks && touch hooks/g.sh
  echo '{}' > settings.json
  ${hooks}
  H1=$(cat settings.json)
  ${hooks}
  [ "$(cat settings.json)" = "$H1" ]
  [ "$(${jq} '[.hooks.PreToolUse[0].hooks[] | select(.command=="/h/hooks/g.sh")] | length' settings.json)" = "1" ]

  # 4. an entry whose hook file no longer exists is pruned (empty groups drop out).
  printf '%s' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/h/hooks/gone.sh"}]}]}}' > settings.json
  ${hooks}
  [ "$(${jq} '[.hooks.PreToolUse[]?.hooks[]? | select(.command=="/h/hooks/gone.sh")] | length' settings.json)" = "0" ]

  # 5. a missing target is created from {}.
  rm settings.json
  ${policy}
  [ "$(${jq} -r '.theme' settings.json)" = "dark" ]

  echo "all reconciler assertions passed" > "$out"
''
