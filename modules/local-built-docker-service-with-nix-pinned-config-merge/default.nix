# local-built-docker-service-with-nix-pinned-config-merge
#
# Run a self-hosted app from a Docker image built ON the host (no registry)
# and keep the security-relevant slice of its runtime JSON config reproducible
# in Nix by jq-merging it into the operator's hand-edited config on every start.
#
# See README.md for the why and the traps. This module is generic: point it at
# a source tree containing a Dockerfile, give the image a tag, and declare the
# pinned config surface. Everything private has been parameterized as options.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.services.localDockerApp;

  # The pinned surface, rendered to a JSON file in the store. Only these keys
  # are authoritative from Nix; the merge below leaves everything else in the
  # operator's runtime config untouched.
  pinnedConfigFile = pkgs.writeText "${cfg.name}-pinned.json" (builtins.toJSON cfg.pinnedConfig);

  # Merges the pinned surface into the runtime config file on every start.
  # Split ownership: the operator owns the file (auth tokens, model choices,
  # agents, …); Nix owns only the keys in `pinnedConfig`, re-applied each start
  # so they can never drift out of version control.
  mergeScript = pkgs.writeShellScript "${cfg.name}-merge-config" ''
    set -eu
    f=${cfg.stateDir}/${cfg.configFileName}
    if [ ! -f "$f" ]; then
      echo '{}' > "$f"
      chown ${toString cfg.runUid}:${toString cfg.runGid} "$f"
      chmod 600 "$f"
    fi
    tmp=$(mktemp)
    ${pkgs.jq}/bin/jq ${escapeShellArg cfg.mergeFilter} \
      --slurpfile pinned ${pinnedConfigFile} \
      "$f" > "$tmp"
    mv "$tmp" "$f"
    chown ${toString cfg.runUid}:${toString cfg.runGid} "$f"
    chmod 600 "$f"
  '';

  runArgs =
    [
      "--rm"
      "--name"
      cfg.containerName
    ]
    ++ cfg.dockerArgs
    ++ optional (cfg.envFile != null) "--env-file=${cfg.envFile}"
    ++ [ cfg.imageTag ]
    ++ cfg.command;

  dockerRun = pkgs.writeShellScript "${cfg.name}-run" ''
    exec ${pkgs.docker}/bin/docker run \
      ${concatMapStringsSep " \\\n      " escapeShellArg runArgs}
  '';
in
{
  options.services.localDockerApp = {
    enable = mkEnableOption "a locally-built (registry-free) Docker service with a Nix-pinned config surface";

    name = mkOption {
      type = types.str;
      default = "localapp";
      description = ''
        Short identifier used to name the systemd units, state dir, and
        rendered store files. Change it if you run more than one instance.
      '';
    };

    runUid = mkOption {
      type = types.int;
      default = 1000;
      description = ''
        Numeric uid the container process runs as. State files are chowned to
        this so the container can read/write them. Must match the uid baked
        into the image (many node/python images use 1000). This is an
        image-specific knob — inspect your image if writes fail with EACCES.
      '';
    };

    runGid = mkOption {
      type = types.int;
      default = 1000;
      description = "Numeric gid the container process runs as. See runUid.";
    };

    sourceDir = mkOption {
      type = types.str;
      example = "/srv/myapp/src";
      description = ''
        Path to the source checkout used as the docker build context. Expected
        to contain a Dockerfile. Sync it in out-of-band (rsync, a deploy step,
        a git checkout on the host) — this module does not fetch source from
        the network.
      '';
    };

    imageTag = mkOption {
      type = types.str;
      example = "myapp:local-1.0.0";
      description = ''
        Tag applied to the locally-built image. TRAP: the build is skipped when
        this tag already exists, so a code change alone rebuilds nothing — bump
        the tag to force a rebuild.
      '';
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/${cfg.name}/state";
      description = "Host directory bind-mounted for persistent state (holds the runtime config file).";
    };

    workspaceDir = mkOption {
      type = types.str;
      default = "/var/lib/${cfg.name}/workspace";
      description = "Host directory bind-mounted for the app's working data (optional; created and chowned like stateDir).";
    };

    containerName = mkOption {
      type = types.str;
      default = cfg.name;
      description = "Name given to the running container (used for rm/stop).";
    };

    configFileName = mkOption {
      type = types.str;
      default = "config.json";
      description = "Basename of the runtime JSON config, relative to stateDir.";
    };

    pinnedConfig = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      example = literalExpression ''
        {
          # e.g. a capability/skill allowlist — the security-relevant surface
          allowList = [ "read-files" "run-shell" ];
          entries."http-fetch" = {
            enabled = true;
            env.BASE_URL = "https://api.example.com/v1";
          };
        }
      '';
      description = ''
        The slice of runtime config that Nix owns. Rendered to JSON and merged
        into the runtime file on every start via `mergeFilter`. Keep only the
        security-relevant / reproducibility-critical keys here; leave volatile
        operator state (tokens, sessions) out so their hand-edits survive.

        SECRETS WARNING: `pinnedConfig` is serialized to a JSON file in the
        world-readable Nix store (mode 0444) — every local user can read it.
        Never put credentials (API keys, tokens, passwords) in it. Route those
        through `envFile` (a runtime path such as `/run/secrets/...`) instead.
      '';
    };

    mergeFilter = mkOption {
      type = types.str;
      default = ". * $pinned[0]";
      description = ''
        jq filter that merges the pinned surface (available as `$pinned[0]`)
        into the existing runtime config (the input `.`). The default does a
        recursive deep merge (`*`), so pinned keys win but sibling operator
        keys survive. Override for surgical control — e.g. to authoritatively
        replace a single subtree rather than deep-merge it:

          .skills = ((.skills // {}) + { allowBundled: $pinned[0].allowBundled,
                                         entries: $pinned[0].entries })
      '';
    };

    command = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "node" "dist/index.js" "gateway" "--bind" "loopback" ];
      description = "Command (and args) to run inside the container, appended after the image tag.";
    };

    dockerArgs = mkOption {
      type = types.listOf types.str;
      default = [
        "--network=host"
        "--cap-drop=NET_RAW"
        "--cap-drop=NET_ADMIN"
        "--security-opt=no-new-privileges:true"
        "--init"
      ];
      description = ''
        Extra `docker run` flags (volumes, env, network, security opts). The
        default set is a locked-down host-network profile: `--network=host` is
        handy when the app must reach a loopback-only backend, and the dropped
        caps + no-new-privileges claw back part of what host networking gives
        away. Include your `-v ${cfg.stateDir}:...` and `-e ...` flags here.
      '';
    };

    envFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Optional path passed to `docker run --env-file`.";
    };

    buildTimeout = mkOption {
      type = types.str;
      default = "60min";
      description = "systemd TimeoutStartSec for the one-shot build unit.";
    };
  };

  config = mkIf cfg.enable {
    virtualisation.docker = {
      enable = true;
      autoPrune.enable = true;
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/${cfg.name}  0755 ${toString cfg.runUid} ${toString cfg.runGid} -"
      "d ${cfg.stateDir}       0700 ${toString cfg.runUid} ${toString cfg.runGid} -"
      "d ${cfg.workspaceDir}   0700 ${toString cfg.runUid} ${toString cfg.runGid} -"
    ];

    # One-shot builder: builds the image from the on-host source context.
    # TRAP: skips when imageTag already exists — bump the tag to rebuild.
    systemd.services."${cfg.name}-build" = {
      description = "${cfg.name} — build local docker image from ${cfg.sourceDir}";
      after = [
        "docker.service"
        "local-fs.target"
      ];
      requires = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [
        docker
        bash
        coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = cfg.buildTimeout;
      };
      script = ''
        set -eu
        if [ ! -f ${cfg.sourceDir}/Dockerfile ]; then
          echo "[${cfg.name}-build] no Dockerfile at ${cfg.sourceDir} — sync source first." >&2
          exit 1
        fi
        if docker image inspect ${cfg.imageTag} >/dev/null 2>&1; then
          echo "[${cfg.name}-build] ${cfg.imageTag} already present; skipping build."
          exit 0
        fi
        echo "[${cfg.name}-build] building ${cfg.imageTag} from ${cfg.sourceDir}"
        docker build -t ${cfg.imageTag} ${cfg.sourceDir}
      '';
    };

    systemd.services.${cfg.name} = {
      description = "${cfg.name} service (local docker image)";
      after = [
        "docker.service"
        "${cfg.name}-build.service"
      ];
      requires = [
        "docker.service"
        "${cfg.name}-build.service"
      ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [ docker ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = 10;
        TimeoutStartSec = "5min";
        ExecStartPre = [
          # leading '-' so a missing container is not an error
          "-${pkgs.docker}/bin/docker rm -f ${cfg.containerName}"
          # re-apply the Nix-pinned config surface before every start
          "${mergeScript}"
        ];
        ExecStart = dockerRun;
        ExecStop = "${pkgs.docker}/bin/docker stop ${cfg.containerName}";
      };
    };
  };
}
