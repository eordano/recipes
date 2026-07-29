# spool-dir-credential-broker — keep a bearer token out of unprivileged
# sandboxes by putting one hardened watcher between them and a REST API.
#
# Unprivileged producers (sandboxed jobs, agents, user sessions) only ever
# drop a JSON manifest into a shared, sticky 1777 spool directory. They never
# see the credential. A single hardened, credential-holding systemd unit
# watches that directory with inotify and is the *only* process that forwards
# the manifests to the upstream REST API.
#
# The token is re-read from `tokenFile` on every request, so rotating the
# secret takes effect with no restart of the watcher.
#
# This module is self-contained: import it, set `enable = true`, and provide
# `tokenFile`, `upstreamUrl`, and `user`. You are responsible for creating the
# spool directory as 1777 (see README) — this unit only reads/writes it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.spoolCredentialBroker;

  watcherScript = pkgs.writeShellApplication {
    name = "spool-credential-broker";
    runtimeInputs = with pkgs; [
      inotify-tools
      curl
      jq
      coreutils
    ];
    text = ''
      set -euo pipefail

      SPOOL="''${SPOOL:?SPOOL required}"
      TOKEN_FILE="''${TOKEN_FILE:?TOKEN_FILE required}"
      UPSTREAM_URL="''${UPSTREAM_URL:?UPSTREAM_URL required}"
      CREATE_PATH="''${CREATE_PATH:-/api/sessions}"
      DELETE_PATH="''${DELETE_PATH:-/api/sessions}"
      ID_FIELD="''${ID_FIELD:-slug}"

      [ -d "$SPOOL" ]      || { echo "[broker] spool $SPOOL missing" >&2; exit 1; }
      [ -r "$TOKEN_FILE" ] || { echo "[broker] token $TOKEN_FILE not readable" >&2; exit 1; }

      # Re-read the token on every call: this is the whole point — a rotated
      # secret takes effect without restarting the unit.
      api() {
        local method="$1" path="$2" body="''${3:-}" token
        token=$(tr -d '\n\r' < "$TOKEN_FILE")
        # Never put the token on curl's argv: process arguments are world-
        # readable via /proc/<pid>/cmdline on a stock host, so a local
        # unprivileged producer — exactly the adversary this module confines —
        # could scrape the bearer token out of the in-flight curl. Instead feed
        # the Authorization header through a curl config on stdin (`-K -`), which
        # never appears in the process arguments.
        if [ -n "$body" ]; then
          printf 'header = "Authorization: Bearer %s"\n' "$token" \
          | curl -sS -f -K - -X "$method" \
            -H "Content-Type: application/json" \
            --data "$body" \
            "$UPSTREAM_URL$path"
        else
          printf 'header = "Authorization: Bearer %s"\n' "$token" \
          | curl -sS -f -K - -X "$method" \
            "$UPSTREAM_URL$path"
        fi
      }

      handle_create() {
        local f="$1" body id
        body=$(cat "$SPOOL/$f" 2>/dev/null || return 0)
        id=$(printf '%s' "$body" | jq -r ".$ID_FIELD // empty" 2>/dev/null || true)
        [ -n "$id" ] || { echo "[broker] no .$ID_FIELD in $f, skip" >&2; return 0; }
        if api POST "$CREATE_PATH" "$body" >/dev/null 2>&1; then
          echo "[broker] registered $id ← $f"
        else
          echo "[broker] upstream registration failed for $id" >&2
        fi
      }

      handle_delete() {
        local f="$1"
        # The manifest content is already gone on delete, so the resource id is
        # recovered from the filename (drop the .json suffix).
        local id="''${f%.json}"
        if api DELETE "$DELETE_PATH/$id" >/dev/null 2>&1; then
          echo "[broker] unregistered $id"
        fi
      }

      # Reconcile anything already present before we start watching, so a
      # restart re-forwards manifests that were dropped while we were down.
      shopt -s nullglob
      for f in "$SPOOL"/*.json; do
        bn=$(basename "$f")
        case "$bn" in .*) continue ;; esac
        handle_create "$bn"
      done
      shopt -u nullglob

      echo "[broker] watching $SPOOL → $UPSTREAM_URL"
      # close_write catches finished writes; moved_to catches atomic
      # write-tmp-then-rename producers. Both delete and moved_from tear down.
      inotifywait -m -e close_write,moved_to,delete,moved_from \
        --format '%e %f' "$SPOOL" \
      | while IFS=' ' read -r ev fn; do
          case "$fn" in *.json) ;; *) continue ;; esac
          case "$fn" in .*) continue ;; esac
          case "$ev" in
            CLOSE_WRITE|MOVED_TO) handle_create "$fn" ;;
            DELETE|MOVED_FROM)    handle_delete "$fn" ;;
          esac
        done
    '';
  };
in
{
  options.services.spoolCredentialBroker = {
    enable = lib.mkEnableOption "spool-dir credential broker: forward manifests dropped into a sticky spool dir to an upstream REST API";

    spoolDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/spool-broker/inbox";
      description = ''
        Directory where unprivileged producers drop JSON manifests. This should
        be a sticky (1777) directory so any local process can write its own
        manifest but not touch another's. This module does NOT create it — see
        the README for a systemd.tmpfiles rule.
      '';
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        File containing the bearer token for the upstream API. Keep it out of
        the Nix store (use a secret manager) and readable only by `user`.
        Re-read on every request, so rotation needs no restart.
      '';
      example = "/run/secrets/upstream-token";
    };

    upstreamUrl = lib.mkOption {
      type = lib.types.str;
      description = "Base URL of the upstream REST API the broker forwards to.";
      example = "https://api.example.com";
    };

    createPath = lib.mkOption {
      type = lib.types.str;
      default = "/api/sessions";
      description = "Path POSTed to (with the full manifest body) when a manifest appears.";
    };

    deletePath = lib.mkOption {
      type = lib.types.str;
      default = "/api/sessions";
      description = "Base path DELETEd (as `<deletePath>/<id>`) when a manifest is removed.";
    };

    idField = lib.mkOption {
      type = lib.types.str;
      default = "slug";
      description = ''
        JSON field in each manifest carrying the resource id. Also the manifest
        filename stem (`<id>.json`) so deletes can recover the id from the name.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = "User the broker runs as. Must have read access to `tokenFile`.";
      example = "spool-broker";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = cfg.user;
      defaultText = lib.literalExpression "cfg.user";
      description = "Group the broker runs as.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.spool-credential-broker = {
      description = "Forward spool-dir manifests to an upstream REST API";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "systemd-tmpfiles-setup.service"
      ];
      wants = [ "network-online.target" ];
      environment = {
        SPOOL = cfg.spoolDir;
        TOKEN_FILE = toString cfg.tokenFile;
        UPSTREAM_URL = cfg.upstreamUrl;
        CREATE_PATH = cfg.createPath;
        DELETE_PATH = cfg.deletePath;
        ID_FIELD = cfg.idField;
      };
      serviceConfig = {
        ExecStart = "${watcherScript}/bin/spool-credential-broker";
        User = cfg.user;
        Group = cfg.group;
        Restart = "on-failure";
        RestartSec = 5;
        # Hardening: if the broker is ever compromised it holds the token, so
        # confine it to nothing but reading the token and writing the spool.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadOnlyPaths = [ (toString cfg.tokenFile) ];
        ReadWritePaths = [ cfg.spoolDir ];
      };
    };
  };
}
