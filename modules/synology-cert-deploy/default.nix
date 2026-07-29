# synology-cert-deploy — push externally-issued ACME certs into Synology DSM 7.
#
# DSM 7 runs its own web server and ships no ACME client you control. If your
# host already renews certs for the NAS hostname (NixOS security.acme, acme.sh,
# certbot, …), this module is the last mile: it pushes each renewed cert *into*
# the appliance over the DSM web API.
#
# Design point is blast-radius isolation. Each target is a unique DynamicUser
# whose ONLY supplementary group is that target's certGroup, with certPath
# mounted read-only — so a compromised push reads exactly one NAS's private key
# even when several targets share one host. The DSM password arrives via
# LoadCredential (never argv/env). A per-target sha256 state file makes the
# daily, jittered, Persistent timer a cheap no-op until the cert actually
# changes.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.synology-cert-deploy;
  inherit (lib)
    mapAttrs'
    nameValuePair
    mkIf
    mkOption
    mkEnableOption
    types
    ;

  # The uploader is embedded so this module is a single-file drop-in.
  # It talks SYNO.Core.Certificate.import and is idempotent: it hashes the
  # cert material and skips the upload when nothing changed since last run.
  uploader = pkgs.writeText "synology-cert-deploy.py" ''
    #!/usr/bin/env python3
    """synology-cert-deploy - push an externally-issued ACME cert into a DSM 7
    NAS via SYNO.Core.Certificate.import. Idempotent: skips upload if the cert
    content hasn't changed since the last successful run.

    Designed for unattended operation under a systemd service. No interactive
    input. Reads:
      --cert-dir DIR           directory containing fullchain.pem, privkey.pem,
                               chain.pem (chain is optional)
      --password-file PATH     plain-text DSM admin password
      --dsm-url URL            https://host:5001
      --user NAME              DSM admin account
      --desc NAME              friendly name in DSM; also used to find existing
                               cert to replace (otherwise creates new)
      --state-file PATH        where to persist the sha256 of the last
                               successfully pushed cert; a mismatch/missing
                               triggers an upload, a match means skip

    Exit codes: 0 success or skip-no-change; 1 push failed; 2 bad config.
    """
    from __future__ import annotations
    import argparse
    import hashlib
    import json
    import secrets as _secrets
    import ssl
    import sys
    from pathlib import Path
    from urllib import error, parse, request

    # Set once from --verify-tls. Off by default: a fresh NAS serves the
    # self-signed cert this tool is replacing, so verification can't succeed on
    # the bootstrap run. Adopters whose NAS already serves the installed
    # (publicly trusted) cert can turn it on to defeat a MITM on the push path.
    VERIFY_TLS = False


    def _ctx() -> ssl.SSLContext:
        ctx = ssl.create_default_context()
        if not VERIFY_TLS:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        return ctx


    def post(url: str, sid: str | None, token: str | None, params: dict) -> dict:
        if sid:
            params = {**params, "_sid": sid}
        body = parse.urlencode(params).encode()
        req = request.Request(url, data=body, method="POST")
        req.add_header("content-type", "application/x-www-form-urlencoded")
        if token:
            req.add_header("X-SYNO-TOKEN", token)
        ctx = _ctx()
        try:
            with request.urlopen(req, context=ctx, timeout=30) as r:
                return json.loads(r.read())
        except error.HTTPError as e:
            return {"success": False, "error": {"code": e.code, "msg": e.reason}}


    def post_multipart(url: str, sid: str, token: str | None,
                       query: dict, fields: dict, files: dict) -> dict:
        q = {**query, "_sid": sid}
        full_url = f"{url}?{parse.urlencode(q)}"
        boundary = "----syno_cert_" + _secrets.token_hex(12)
        chunks: list[bytes] = []
        for name, val in fields.items():
            chunks.append(f"--{boundary}\r\n".encode())
            chunks.append(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
            chunks.append(str(val).encode())
            chunks.append(b"\r\n")
        for name, (fname, content) in files.items():
            chunks.append(f"--{boundary}\r\n".encode())
            chunks.append(
                f'Content-Disposition: form-data; name="{name}"; filename="{fname}"\r\n'.encode()
            )
            chunks.append(b"Content-Type: application/octet-stream\r\n\r\n")
            chunks.append(content)
            chunks.append(b"\r\n")
        chunks.append(f"--{boundary}--\r\n".encode())
        body = b"".join(chunks)
        req = request.Request(full_url, data=body, method="POST")
        req.add_header("content-type", f"multipart/form-data; boundary={boundary}")
        if token:
            req.add_header("X-SYNO-TOKEN", token)
        ctx = _ctx()
        try:
            with request.urlopen(req, context=ctx, timeout=120) as r:
                return json.loads(r.read())
        except error.HTTPError as e:
            return {"success": False, "error": {"code": e.code, "msg": e.reason}}


    def log(msg: str) -> None:
        print(msg, flush=True)


    def main() -> int:
        p = argparse.ArgumentParser()
        p.add_argument("--dsm-url", required=True)
        p.add_argument("--user", required=True)
        p.add_argument("--password-file", required=True)
        p.add_argument("--cert-dir", required=True)
        p.add_argument("--desc", required=True)
        p.add_argument("--state-file", required=True)
        p.add_argument("--default", action="store_true",
                       help="set as DSM default cert (services without a binding fall back to it)")
        p.add_argument("--verify-tls", action="store_true",
                       help="verify the DSM cert against the system trust store "
                            "(only works once the NAS serves a publicly trusted cert)")
        args = p.parse_args()

        global VERIFY_TLS
        VERIFY_TLS = args.verify_tls

        cert_dir = Path(args.cert_dir)
        fullchain = cert_dir / "fullchain.pem"
        # NixOS security.acme writes the private key as `key.pem`; acme.sh /
        # certbot use `privkey.pem`. Accept either.
        privkey = cert_dir / "key.pem"
        if not privkey.is_file():
            privkey = cert_dir / "privkey.pem"
        chain = cert_dir / "chain.pem"
        for required in (fullchain, privkey):
            if not required.is_file():
                log(f"missing required file: {required}")
                return 2

        cert_pem = fullchain.read_bytes()
        key_pem = privkey.read_bytes()
        chain_pem = chain.read_bytes() if chain.is_file() else None

        h = hashlib.sha256()
        h.update(cert_pem); h.update(b"\0")
        h.update(key_pem); h.update(b"\0")
        if chain_pem is not None:
            h.update(chain_pem)
        digest = h.hexdigest()

        state_path = Path(args.state_file)
        if state_path.is_file():
            prev = state_path.read_text().strip()
            if prev == digest:
                log(f"unchanged ({digest[:12]}), skip")
                return 0

        password = Path(args.password_file).read_text().rstrip("\n")

        url = args.dsm_url.rstrip("/") + "/webapi/entry.cgi"
        login = post(url, None, None, {
            "api": "SYNO.API.Auth", "method": "login", "version": "7",
            "account": args.user, "passwd": password,
            "session": "SynoCertDeploy", "format": "sid",
            "enable_syno_token": "yes",
        })
        if not login.get("success"):
            log(f"login failed: {login.get('error')}")
            return 1
        sid = login["data"]["sid"]
        token = login["data"].get("synotoken")

        try:
            listing = post(url, sid, token, {
                "api": "SYNO.Core.Certificate.CRT", "method": "list", "version": "1",
            })
            if not listing.get("success"):
                log(f"cert list failed: {listing.get('error')}")
                return 1
            target_id = ""
            for c in listing.get("data", {}).get("certificates", []):
                if c.get("desc") == args.desc:
                    target_id = c.get("id", "")
                    log(f"replacing existing cert id={target_id} desc={args.desc!r}")
                    break
            if not target_id:
                log(f"no existing cert with desc={args.desc!r}; uploading new")

            files = {
                "cert": ("fullchain.pem", cert_pem),
                "key": ("privkey.pem", key_pem),
            }
            if chain_pem is not None:
                files["inter_cert"] = ("chain.pem", chain_pem)
            fields = {
                "id": target_id,
                "desc": args.desc,
                "as_default": "true" if args.default else "",
            }
            r = post_multipart(
                url, sid, token,
                {"api": "SYNO.Core.Certificate", "method": "import", "version": "1"},
                fields, files,
            )
            if not r.get("success"):
                log(f"import failed: {r.get('error')}")
                return 1
            new_id = (r.get("data") or {}).get("id") or target_id or "?"
            log(f"OK pushed cert (id={new_id}, sha256={digest[:12]})")

            state_path.parent.mkdir(parents=True, exist_ok=True)
            state_path.write_text(digest + "\n")
            return 0
        finally:
            post(url, sid, token, {
                "api": "SYNO.API.Auth", "method": "logout", "version": "7",
                "session": "SynoCertDeploy",
            })


    if __name__ == "__main__":
        sys.exit(main())
  '';
in
{
  options.modules.synology-cert-deploy = {
    enable = mkEnableOption "push externally-issued ACME certs to Synology DSM 7";

    hosts = mkOption {
      default = { };
      description = ''
        Map of <name> -> push-target config. Each entry creates one systemd
        service + one daily timer. Each runs as a unique DynamicUser with
        SupplementaryGroups=[<certGroup>], so a service can only read its own
        cert files; cross-host blast radius stays at one NAS.
      '';
      type = types.attrsOf (
        types.submodule {
          options = {
            dsmUrl = mkOption {
              type = types.str;
              example = "https://your-nas:5001";
              description = "https://<host>:5001 — DSM web API base.";
            };
            user = mkOption {
              type = types.str;
              default = "admin";
              description = "DSM admin account used to upload the cert.";
            };
            passwordFile = mkOption {
              type = types.path;
              example = "/run/secrets/nas-admin-password";
              description = ''
                Path to a plain-text file holding the DSM admin password.
                Point this at a secret manager's decrypted path (agenix,
                sops-nix, systemd-creds, …). It is read into a systemd
                credential, never passed on argv or in the environment.
              '';
            };
            certPath = mkOption {
              type = types.str;
              example = "/var/lib/acme/nas.example.com";
              description = ''
                Directory holding fullchain.pem plus key.pem or privkey.pem
                (chain.pem optional). For NixOS security.acme this is
                /var/lib/acme/<cert-name>.
              '';
            };
            certGroup = mkOption {
              type = types.str;
              example = "nas-cert";
              description = ''
                The Unix group that owns the cert files in certPath. The deploy
                service joins this group as its only supplementary group, so it
                can read this one cert's privkey and nothing else. For NixOS
                security.acme, set the cert's `group` to a per-NAS group and
                pass the same name here.
              '';
            };
            desc = mkOption {
              type = types.str;
              example = "nas.example.com";
              description = "Friendly name shown in DSM and used to find the existing cert to replace.";
            };
            asDefault = mkOption {
              type = types.bool;
              default = false;
              description = "Mark the imported cert as DSM's default.";
            };
            verifyTls = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Verify the DSM server certificate against the system trust store
                before sending the admin password and private key. Defaults to
                false because a fresh NAS serves the self-signed cert this module
                is replacing, so verification cannot succeed on the bootstrap
                run. Once the NAS serves the (publicly trusted) cert this module
                installs — and dsmUrl uses a hostname that cert covers — set this
                to true to defeat a man-in-the-middle on the push path.
              '';
            };
            onCalendar = mkOption {
              type = types.str;
              default = "daily";
              description = "Systemd OnCalendar expression for the timer.";
            };
            randomizedDelay = mkOption {
              type = types.str;
              default = "1h";
              description = "Spread the timer firings to avoid thundering-herd against the NAS.";
            };
          };
        }
      );
    };
  };

  config = mkIf (cfg.enable && cfg.hosts != { }) {
    systemd.tmpfiles.rules = [
      "d /var/lib/synology-cert-deploy 0755 root root - -"
    ];

    systemd.services = mapAttrs' (
      name: host:
      nameValuePair "synology-cert-deploy-${name}" {
        description = "Push ACME cert to Synology ${name} (${host.dsmUrl})";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          DynamicUser = true;
          SupplementaryGroups = [ host.certGroup ];
          StateDirectory = "synology-cert-deploy/${name}";
          StateDirectoryMode = "0700";
          LoadCredential = "password:${host.passwordFile}";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          RestrictNamespaces = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          RestrictRealtime = true;
          SystemCallArchitectures = "native";
          ReadOnlyPaths = [ host.certPath ];
          ExecStart = lib.concatStringsSep " " [
            "${pkgs.python3}/bin/python3"
            "${uploader}"
            "--dsm-url ${lib.escapeShellArg host.dsmUrl}"
            "--user ${lib.escapeShellArg host.user}"
            ''--password-file "''${CREDENTIALS_DIRECTORY}/password"''
            "--cert-dir ${lib.escapeShellArg host.certPath}"
            "--desc ${lib.escapeShellArg host.desc}"
            "--state-file /var/lib/synology-cert-deploy/${name}/last-sha256"
            (lib.optionalString host.asDefault "--default")
            (lib.optionalString host.verifyTls "--verify-tls")
          ];
        };
      }
    ) cfg.hosts;

    systemd.timers = mapAttrs' (
      name: host:
      nameValuePair "synology-cert-deploy-${name}" {
        description = "Periodic cert push for Synology ${name}";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = host.onCalendar;
          Persistent = true;
          RandomizedDelaySec = host.randomizedDelay;
          Unit = "synology-cert-deploy-${name}.service";
        };
      }
    ) cfg.hosts;
  };
}
