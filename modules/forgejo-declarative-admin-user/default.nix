{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.forgejo-admin-user;

  readyCurlArgs = lib.optionalString (
    cfg.readyUnixSocket != null
  ) "--unix-socket ${lib.escapeShellArg cfg.readyUnixSocket} ";

  bootstrapScript = pkgs.writeShellScript "forgejo-admin-user-bootstrap" ''
    set -eu
    export PATH=${
      lib.makeBinPath [
        pkgs.curl
        pkgs.coreutils
      ]
    }:$PATH

    PW=$(cat ${lib.escapeShellArg cfg.passwordFile})

    echo "Waiting for Forgejo to answer ${cfg.readyUrl} ..."
    for i in $(seq 1 ${toString cfg.readyTimeoutSec}); do
      if curl -sf -o /dev/null ${readyCurlArgs}${lib.escapeShellArg cfg.readyUrl}; then
        echo "Forgejo is up."
        break
      fi
      sleep 1
    done
    if ! curl -sf -o /dev/null ${readyCurlArgs}${lib.escapeShellArg cfg.readyUrl}; then
      echo "Forgejo did not become ready in ${toString cfg.readyTimeoutSec}s — aborting bootstrap."
      exit 1
    fi

    # Idempotent create. `|| true` because forgejo errors on "already exists";
    # the change-password below is the actual desired-state enforcer.
    echo "Ensuring admin user '${cfg.username}' exists ..."
    ${cfg.forgejoCli} admin user create \
      --admin \
      --username ${lib.escapeShellArg cfg.username} \
      --email ${lib.escapeShellArg cfg.email} \
      --password "$PW" \
      --must-change-password=false \
      || true

    # --must-change-password=false is REQUIRED: forgejo's change-password
    # defaults that flag to true, which would force a password change on next
    # login and make the user's automated API calls fail with 403 (an unattended
    # client can't complete an interactive password change). Without it the user
    # is created fine but every API/mirror call 403s.
    echo "Setting password for '${cfg.username}' to current secret value ..."
    ${cfg.forgejoCli} admin user change-password \
      --username ${lib.escapeShellArg cfg.username} \
      --password "$PW" \
      --must-change-password=false

    echo "forgejo-admin-user: done."
  '';
in
{
  options.services.forgejo-admin-user = {
    enable = lib.mkEnableOption "declaratively create + maintain an admin user on this Forgejo host";

    username = lib.mkOption {
      type = lib.types.str;
      default = "automation";
      description = "Username for the managed admin user (used for automated API / mirror auth).";
    };

    email = lib.mkOption {
      type = lib.types.str;
      example = "automation@example.com";
      description = "Email for the managed admin user (required by Forgejo).";
    };

    passwordFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a file containing the admin user's password. Pass a path from
        whatever secret manager you use (agenix, sops-nix, {file}`/run/secrets/…`).
        Read at run time, so the password itself never enters the Nix store.

        The unit lists this path in {option}`restartTriggers`, but be clear on
        what that can and cannot catch: `X-Restart-Triggers` records the
        trigger's *text*, so it fires only when the path string itself differs
        between generations. A secret manager that rotates the *contents*
        behind a stable runtime path ({file}`/run/secrets/…`,
        {file}`/run/agenix/…`) will NOT trip it, and this module deliberately
        does not hash the file's contents — that would copy the password into
        the world-readable store. **After rotating the secret, restart
        `forgejo-admin-user.service` yourself** (or reboot); the
        `change-password` step is idempotent, so re-running it is always safe.
      '';
      example = "/run/secrets/forgejo-admin-password";
    };

    forgejoCli = lib.mkOption {
      type = lib.types.str;
      description = ''
        Shell command prefix that invokes the Forgejo CLI with the right
        {option}`--config` / {option}`--work-path` for this host. The bootstrap
        script appends `admin user create …` / `admin user change-password …`.

        Native `services.forgejo` (binary called directly; run the unit as the
        forgejo user so the CLI can read the data dir):

        ```
        "''${pkgs.forgejo}/bin/forgejo --config /var/lib/forgejo/custom/conf/app.ini"
        ```

        Forgejo running inside a container (exec into it; run the unit as root):

        ```
        "podman exec -i forgejo forgejo --config /data/custom/conf/app.ini"
        ```
      '';
      example = "\${pkgs.forgejo}/bin/forgejo --config /var/lib/forgejo/custom/conf/app.ini";
    };

    serviceUser = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = ''
        Which user the bootstrap oneshot runs as. Use `"forgejo"` for a native
        `services.forgejo` host (the CLI must be able to read the data dir), or
        `"root"` for a container-exec wrapper.
      '';
    };

    afterUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "network-online.target" ];
      example = [ "forgejo.service" ];
      description = "Systemd units this bootstrap must wait for before running (e.g. the Forgejo service unit).";
    };

    readyUrl = lib.mkOption {
      type = lib.types.str;
      description = ''
        HTTP URL that returns 2xx when Forgejo is ready — typically the local API
        version probe. For a unix-socket Forgejo set this to a host-less URL such
        as `http://localhost/api/v1/version` and point {option}`readyUnixSocket`
        at the socket.
      '';
      example = "http://127.0.0.1:3000/api/v1/version";
    };

    readyUnixSocket = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/forgejo/forgejo.sock";
      description = ''
        If set, the readiness probe connects via this unix socket
        (`curl --unix-socket`) instead of opening a TCP connection. Required for a
        native `services.forgejo` host that listens on a socket with no TCP port.
      '';
    };

    readyTimeoutSec = lib.mkOption {
      type = lib.types.int;
      default = 180;
      description = "How long to wait for readyUrl before aborting.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.forgejo-admin-user = {
      description = "Bootstrap / maintain the managed admin user on this Forgejo host";
      after = cfg.afterUnits;
      wants = cfg.afterUnits;
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ cfg.passwordFile ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 10;
        User = cfg.serviceUser;
        ExecStart = bootstrapScript;
      };
    };
  };
}
