# forgejo-bidirectional-safe-sync
#
# A NixOS module that bidirectionally mirrors two Forgejo instances from a
# neutral third box. Each timer tick walks every repo on both sides via the
# Forgejo API and reconciles refs *symmetrically*:
#
#   - fast-forward a ref wherever it is safe (one side strictly ahead),
#   - propagate brand-new repos/refs,
#   - and ALERT on genuine divergence instead of force-pushing over either side.
#
# Because the sync runs on a third host, neither forge depends on the other for
# backup / HA: if one goes down, the survivor keeps its full copy and the box
# reconciles once the peer returns.
#
# This module is only the packaging (system user, secret plumbing, timer +
# hardened oneshot service). The actual reconciliation engine is an external
# script you point `syncScript` at; the env-var contract it must consume is
# documented in the README and materialized by `envSetup` below.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.forgejo-bisync;

  # Runtime dir lives on tmpfs (/run) — see the EnvironmentFile trap below.
  runDir = "/run/${cfg.user}";
  envFile = "${runDir}/env";

  # Runs as cfg.user, not root: RuntimeDirectory already creates ${runDir}
  # owned by that user, and the secret is read through LoadCredential, which
  # lets systemd's PID1 (still root) read passwordFile on the unit's behalf
  # and hand it over via $CREDENTIALS_DIRECTORY -- so this works regardless of
  # whether passwordFile is readable by anyone but root, and nothing here
  # needs the `+` root-prefix it used to.
  envSetup = pkgs.writeShellScript "forgejo-bisync-env" ''
    set -eu
    PW=$(cat "$CREDENTIALS_DIRECTORY/password")
    umask 077
    cat > ${envFile} <<EOF
    BISYNC_USERNAME=${cfg.username}
    BISYNC_PASSWORD=$PW
    BISYNC_A_NAME=${(builtins.elemAt cfg.instances 0).name}
    BISYNC_A_BASE_URL=${(builtins.elemAt cfg.instances 0).baseUrl}
    BISYNC_B_NAME=${(builtins.elemAt cfg.instances 1).name}
    BISYNC_B_BASE_URL=${(builtins.elemAt cfg.instances 1).baseUrl}
    BISYNC_WORK_DIR=${cfg.workDir}
    BISYNC_STATE_FILE=${cfg.workDir}/state.json
    BISYNC_PARALLELISM=${toString cfg.parallelism}
    BISYNC_ALERT_DIVERGE_MS=${toString cfg.alertOnDivergeAfterMs}
    BISYNC_EXCLUDE_REPOS=${lib.concatStringsSep "," cfg.excludeRepos}
    BISYNC_EXCLUDE_OWNERS=${lib.concatStringsSep "," cfg.excludeOwners}
    BISYNC_UNOWNED_TARGET=${lib.optionalString (cfg.unownedReposTarget != null) cfg.unownedReposTarget}
    EOF
    chmod 0400 ${envFile}
  '';
in
{
  options.services.forgejo-bisync = {
    enable = lib.mkEnableOption "forgejo-bisync: bidirectional safe-sync between two Forgejos";

    syncScript = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to the reconciliation engine. It is invoked once per timer tick and
        reads its configuration entirely from the BISYNC_* environment variables
        materialized into the tmpfs env file (see README for the full contract).
        The default runner assumes a Node/TypeScript script executed with
        `node --experimental-strip-types`; override `interpreter` for anything
        else (e.g. a standalone executable or a Python script).
      '';
    };

    interpreter = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = [
        "${pkgs.nodejs}/bin/node"
        "--experimental-strip-types"
      ];
      description = ''
        Argv prefix used to run `syncScript`. Set to null to execute the script
        directly (it must be executable and carry its own shebang).
      '';
    };

    instances = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Short name used in logs and as the git remote name. Lowercase, no spaces.";
              example = "forge-a";
            };
            baseUrl = lib.mkOption {
              type = lib.types.str;
              description = "https://… base URL of the Forgejo instance (no trailing slash).";
              example = "https://forge-a.example.com";
            };
          };
        }
      );
      description = "Exactly two Forgejo instances. Sync is symmetric.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "forgejo-bisync";
      description = "System user/group the sync service runs as. Also names the /run subdir.";
    };

    username = lib.mkOption {
      type = lib.types.str;
      default = "bisync";
      description = ''
        Admin user that exists on BOTH Forgejo instances with the SAME password.
        The daemon uses this username + passwordFile for HTTP Basic Auth against
        both instances (repo discovery via the API, and git over HTTPS). Give it
        an admin token/role so the API can enumerate every repo and create repos
        on either side. You are responsible for provisioning this identical
        account on both forges (e.g. a small declarative bootstrap on each host).
      '';
    };

    passwordFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a file containing the shared admin password. Use whatever secret
        manager you like (agenix, sops-nix, systemd credentials, …); the module
        only needs a readable path. The SAME password must be set for `username`
        on both Forgejo instances.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "5min";
      description = "systemd OnUnitActiveSec — how often to run a sync cycle.";
    };

    workDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/forgejo-bisync";
      description = "Working directory (bare clones + state.json).";
    };

    parallelism = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Repos processed concurrently. The reference engine is sequential (1).";
    };

    alertOnDivergeAfterMs = lib.mkOption {
      type = lib.types.int;
      default = 30 * 60 * 1000;
      description = "Emit `alert-divergence` only after a ref has been diverged this long (ms).";
    };

    excludeRepos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "owner/private-repo" ];
      description = "owner/name strings to skip entirely.";
    };

    excludeOwners = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "mirrors" ];
      description = "Whole owners (users or orgs) to skip.";
    };

    unownedReposTarget = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        If a source-side repo's owner doesn't exist on the target side, create
        the propagated repo under THIS org instead. Must be an existing org on
        the target. Default null = skip + alert on owner mismatch.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.length cfg.instances == 2;
        message = "services.forgejo-bisync.instances must list exactly 2 Forgejo instances.";
      }
      {
        assertion = (builtins.elemAt cfg.instances 0).name != (builtins.elemAt cfg.instances 1).name;
        message = "forgejo-bisync: the two instances must have distinct `name` values.";
      }
      {
        assertion = cfg.user != "root";
        message = ''
          services.forgejo-bisync.user must not be root. The sync cycle reads its
          shared password via a systemd credential and never needs privilege.
        '';
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      home = cfg.workDir;
      description = "forgejo-bisync sync daemon";
    };
    users.groups.${cfg.user} = { };

    systemd.tmpfiles.rules = [
      "d ${cfg.workDir}        0750 ${cfg.user} ${cfg.user} - -"
      "d ${cfg.workDir}/work   0750 ${cfg.user} ${cfg.user} - -"
    ];

    systemd.services.forgejo-bisync = {
      description = "Forgejo bidirectional safe-sync cycle";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [
        pkgs.git
        pkgs.coreutils
        pkgs.openssh
      ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.user;
        # RuntimeDirectory replaces the manual `install -d -o -g` that used to
        # need root; LoadCredential replaces the root-only `cat` of
        # passwordFile. Neither ExecStartPre nor ExecStart runs privileged.
        RuntimeDirectory = cfg.user;
        RuntimeDirectoryMode = "0750";
        LoadCredential = "password:${cfg.passwordFile}";
        ExecStartPre = [ "${envSetup}" ];
        ExecStart = lib.concatStringsSep " " (
          (lib.optionals (cfg.interpreter != null) cfg.interpreter) ++ [ (toString cfg.syncScript) ]
        );
        # NOTE the leading `-`: optional-load. /run is tmpfs, so on the first
        # cycle after boot the env file does not exist yet, and systemd loads
        # EnvironmentFile BEFORE running ExecStartPre (which creates it).
        # Without the `-`, the unit dies with "Failed to load environment files"
        # before envSetup can run — a permanent boot-time loop. The `-` lets the
        # first load no-op; envSetup then writes the file for ExecStart to read.
        EnvironmentFile = "-${envFile}";
        WorkingDirectory = cfg.workDir;

        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.workDir ];
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        # Transient network/API failures are expected and fine: no Restart, the
        # next timer tick retries. A stale ref survives at most one interval.
        Restart = "no";
      };
    };

    systemd.timers.forgejo-bisync = {
      description = "Periodic Forgejo bidirectional safe-sync";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = cfg.interval;
        AccuracySec = "30s";
        Unit = "forgejo-bisync.service";
      };
    };
  };
}
