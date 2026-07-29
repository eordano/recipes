# synology-cert-deploy

Push an externally-issued ACME certificate into a **Synology DSM 7** NAS —
automatically, on a timer, with a minimal blast radius if the pusher is ever
compromised.

## The problem

DSM 7 runs its own web server and ships **no ACME client you can drive**. You
can renew a cert for the NAS's hostname on some other machine you control
(NixOS `security.acme`, `acme.sh`, `certbot`, …), but then you're stuck doing
the *last mile* by hand: logging into DSM and re-uploading the PEM every ~60
days. Miss it and the appliance serves an expired cert.

This module closes that gap. It runs a small uploader against the DSM web API
(`SYNO.Core.Certificate.import`) that replaces the named cert in place, driven
by a daily systemd timer.

## The insight / traps

- **Isolation is the design point, not an afterthought.** Each NAS gets its own
  systemd service running as a unique `DynamicUser` whose *only* supplementary
  group is that cert's owning group, with the cert directory mounted
  read-only. So even if you push certs to several appliances from one host, a
  compromise of one pusher can read exactly **one** NAS's private key — never
  the others, never anything else on the box. Pair it with a per-cert group
  (e.g. NixOS `security.acme.certs.<name>.group`).

- **The password never touches argv or the environment.** It's handed to the
  service via `LoadCredential`, so it can't leak through `/proc/<pid>/cmdline`,
  `ps`, or an inherited environment. The uploader reads it from
  `$CREDENTIALS_DIRECTORY/password`.

- **Idempotent by hash.** The uploader sha256's the cert material and records it
  in a per-target state file. If nothing changed, it logs `skip` and exits 0 —
  so a *daily* timer against a cert that renews every ~60 days is essentially
  free, yet re-pushes within a day of any renewal.

- **`desc` is dual-purpose.** It's both the friendly name shown in DSM **and**
  the key used to locate the existing cert to replace. Get it wrong and you
  create a *second* cert instead of updating the one already bound to your
  services. Keep it stable.

- **Jitter + catch-up.** `RandomizedDelaySec` spreads firings so several
  targets don't hammer their appliances in lockstep; `Persistent=true` runs a
  push that was missed while the host was down.

- **TLS to DSM is unverified by default — and that channel carries secrets.**
  The initial cert on a fresh NAS is self-signed — the very thing you're
  replacing — so out of the box the uploader talks to the DSM API without
  verifying its cert. Be clear on what that costs: each run sends the **DSM admin
  password** and the **private key** over that connection, so anyone able to
  intercept the pusher↔NAS path (ARP/DNS spoof, rogue gateway, compromised
  switch) can impersonate the NAS, capture both, and return a fake success. The
  "trusted network path" guidance is therefore load-bearing, not optional. Once
  the NAS serves the publicly trusted cert this module installs (and `dsmUrl`
  uses a hostname that cert covers), set `verifyTls = true` to verify against the
  system trust store and close the MITM window.

- **Private-key filename varies.** NixOS `security.acme` writes `key.pem`;
  `acme.sh` / `certbot` write `privkey.pem`. The uploader accepts either.
  `chain.pem` is optional.

## Usage

Import the module and declare one entry per NAS:

```nix
{
  imports = [ ./synology-cert-deploy ];

  modules.synology-cert-deploy = {
    enable = true;
    hosts.nas = {
      dsmUrl       = "https://your-nas:5001";
      passwordFile = "/run/secrets/nas-admin-password"; # a secret manager's decrypted path
      certPath     = "/var/lib/acme/nas.example.com";
      certGroup    = "nas-cert";      # the Unix group that owns the cert files
      desc         = "nas.example.com";
      asDefault    = true;            # optional: make it DSM's default cert
    };
  };
}
```

On NixOS, arrange for the cert to exist and be group-readable — for example:

```nix
users.groups.nas-cert = { };
security.acme.certs."nas.example.com".group = "nas-cert";
```

### Options (per `hosts.<name>` entry)

| Option           | Default   | Meaning |
|------------------|-----------|---------|
| `dsmUrl`         | —         | `https://<host>:5001` — DSM web API base. |
| `user`           | `admin`   | DSM admin account used to upload. |
| `passwordFile`   | —         | Path to a plain-text file with the DSM admin password (loaded via `LoadCredential`). |
| `certPath`       | —         | Directory with `fullchain.pem` + `key.pem`/`privkey.pem` (+ optional `chain.pem`). |
| `certGroup`      | —         | Unix group owning the cert files; the service's *only* supplementary group. |
| `desc`           | —         | Friendly name in DSM; also the key used to find the cert to replace. |
| `asDefault`      | `false`   | Mark the imported cert as DSM's default. |
| `verifyTls`      | `false`   | Verify the DSM cert against the system trust store before sending secrets. Leave off for the self-signed bootstrap; turn on once the NAS serves the installed cert. |
| `onCalendar`     | `daily`   | Systemd `OnCalendar` for the timer. |
| `randomizedDelay`| `1h`      | `RandomizedDelaySec` jitter. |

## Caveats

- Written for **DSM 7**. Earlier DSM versions use different API versions/paths.
- The admin account needs permission to import certificates. A dedicated,
  least-privileged admin account is preferable to your primary login.
- Force a run and watch it with
  `systemctl start synology-cert-deploy-<name> && journalctl -u synology-cert-deploy-<name> -e`.
- First run creates the cert if `desc` matches nothing; delete the stray
  DSM-generated self-signed cert once yours is bound.
