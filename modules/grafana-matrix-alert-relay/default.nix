# grafana-matrix-alert-relay
#
# A tiny NixOS module that bridges Grafana's webhook contact point to a Matrix
# room. Grafana can only POST JSON to a URL; the Matrix send API is
# `PUT /_matrix/client/v3/rooms/{room}/send/m.room.message/{txn}` and needs a
# caller-supplied transaction id Grafana cannot generate. This relay listens on
# loopback, re-shapes each alert into a well-formed Matrix PUT, and uses a
# deterministic (sha1-of-body, 5-minute bucket) transaction id so retries and
# duplicate deliveries collapse server-side instead of spamming the room.
#
# Import it, set the options, and point a Grafana webhook contact point at
# http://127.0.0.1:<port>/alert (any path works — the relay accepts every POST).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.grafana-matrix-alert-relay;

  relayScript = pkgs.writeText "grafana-matrix-relay.py" ''
    """Webhook -> Matrix relay for Grafana alerts."""
    import datetime as dt
    import hashlib
    import http.server
    import json
    import os
    import sys
    import urllib.parse
    import urllib.request

    PORT = int(os.environ.get("RELAY_PORT", "9099"))
    MATRIX_BASE = os.environ["MATRIX_BASE"].rstrip("/")
    ROOM = os.environ["MATRIX_ROOM"]
    with open(os.environ["MATRIX_TOKEN_FILE"]) as _f:
        TOKEN = _f.read().strip()

    STATUS_PREFIX = {
        "firing": "[FIRING]",
        "resolved": "[RESOLVED]",
        "pending": "[PENDING]",
    }


    def format_alert(a: dict) -> str:
        labels = a.get("labels", {}) or {}
        annot = a.get("annotations", {}) or {}
        status = a.get("status", "?")
        name = labels.get("alertname") or annot.get("summary") or "alert"
        prefix = STATUS_PREFIX.get(status, f"[{status}]")
        summary = annot.get("summary") or annot.get("description") or name
        if len(summary) > 400:
            summary = summary[:400] + "..."
        host = labels.get("host") or labels.get("instance") or ""
        host_str = f" host={host}" if host else ""
        return f"{prefix} {name}{host_str}: {summary}"


    def deterministic_txn(body: str) -> str:
        # sha1 of the body, bucketed into 5-minute windows. Identical alerts
        # delivered/retried within the same window reuse the same txn id, so the
        # Matrix server dedupes them instead of posting the message twice.
        h = hashlib.sha1(body.encode()).hexdigest()
        bucket = int(dt.datetime.now().timestamp() // 300)
        return f"grafana-{bucket}-{h[:16]}"


    def post_matrix(body: str) -> int:
        txn = deterministic_txn(body)
        encoded_room = urllib.parse.quote(ROOM, safe="")
        url = f"{MATRIX_BASE}/_matrix/client/v3/rooms/{encoded_room}/send/m.room.message/{txn}"
        payload = json.dumps({"msgtype": "m.text", "body": body}).encode()
        req = urllib.request.Request(
            url, data=payload, method="PUT",
            headers={
                "Authorization": f"Bearer {TOKEN}",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status


    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0") or 0)
            raw = self.rfile.read(length).decode("utf-8", "replace")
            try:
                payload = json.loads(raw)
            except Exception:
                self.send_response(400)
                self.end_headers()
                return
            alerts = payload.get("alerts") or []
            if not alerts:
                self.send_response(204)
                self.end_headers()
                return
            for a in alerts:
                try:
                    body = format_alert(a)
                    post_matrix(body)
                except Exception as exc:
                    sys.stderr.write(f"matrix post failed: {exc}\n")
            self.send_response(200)
            self.end_headers()

        def log_message(self, fmt, *args):
            sys.stderr.write("relay " + (fmt % args) + "\n")


    def main():
        srv = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
        sys.stderr.write(f"relay listening on 127.0.0.1:{PORT} -> room {ROOM}\n")
        srv.serve_forever()


    if __name__ == "__main__":
        main()
  '';
in
{
  options.services.grafana-matrix-alert-relay = {
    enable = lib.mkEnableOption "webhook -> Matrix relay for Grafana alerts";

    port = lib.mkOption {
      type = lib.types.port;
      default = 9099;
      description = "Loopback port the relay listens on. Point Grafana's webhook contact point at http://127.0.0.1:<port>/alert.";
    };

    matrixBase = lib.mkOption {
      type = lib.types.str;
      example = "https://matrix.example.com";
      description = "Base URL of the Matrix homeserver's client-server API.";
    };

    room = lib.mkOption {
      type = lib.types.str;
      example = "!aBcDeFgHiJkLmNoPqR:example.com";
      description = ''
        Internal Matrix room ID (starts with `!`, not the human `#alias`) that
        alerts are posted to. Not a secret — room IDs are public identifiers;
        the bearer token is what gates posting. The relay's bot account must
        already be joined to this room.
      '';
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      example = "/run/secrets/matrix-alert-token";
      description = ''
        Path to a file containing the Matrix bearer access token as its raw
        value (no `KEY=` env-file prefix, no trailing newline required). It is
        handed to the unit via systemd `LoadCredential`, so it never appears in
        the environment or on the command line. Provide it with your secret
        manager of choice (agenix, sops-nix, a deploy step, ...).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.grafana-matrix-alert-relay = {
      description = "Webhook -> Matrix relay for Grafana alerts";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        RELAY_PORT = toString cfg.port;
        MATRIX_BASE = cfg.matrixBase;
        MATRIX_ROOM = cfg.room;
        # %d is the systemd credentials directory; see LoadCredential below.
        MATRIX_TOKEN_FILE = "%d/matrix-token";
      };

      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        # Token is materialised into the per-unit credentials dir (0400, owned
        # by the DynamicUser), readable at %d/matrix-token — never in env/argv.
        LoadCredential = "matrix-token:${cfg.tokenFile}";
        ExecStart = "${pkgs.python3}/bin/python3 ${relayScript}";
        Restart = "on-failure";
        RestartSec = "10s";

        NoNewPrivileges = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        PrivateTmp = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";

        # Egress is left open (0.0.0.0/0) because the relay needs DNS plus the
        # Matrix homeserver, and the token-gated room is the real security
        # boundary — a tighter allowlist buys little here. If you want
        # per-hostname egress control, front it with an egress proxy instead.
        IPAddressDeny = "any";
        IPAddressAllow = [
          "127.0.0.0/8"
          "::1/128"
          "0.0.0.0/0"
          "::/0"
        ];
      };
    };
  };
}
