# vaultwarden-gvisor-sandbox

A NixOS module that runs a self-hosted [Vaultwarden](https://github.com/dani-garcia/vaultwarden)
(Bitwarden-compatible) password vault as a **gVisor-sandboxed** podman container,
built from a **locally-produced, registry-free** reproducible image, with nginx
terminating TLS in front of it.

## The problem

A secrets vault is about the highest-value target on your network. Two failure
modes worry you most:

1. A container escape or a Vaultwarden RCE reaching the **host kernel**.
2. A poisoned or moved **upstream image** silently changing what you run.

This module addresses both without giving up on containers.

## The approach

- **gVisor sandbox.** The container runs under `--runtime=runsc-host`. Syscalls
  hit gVisor's user-space kernel (`runsc`) instead of the host kernel, so a
  container escape has a much smaller and better-isolated surface to attack.
  The module registers the `runsc-host` runtime for podman itself, so it is
  self-contained.

- **Image built locally.** Instead of `docker pull`, the image is produced with
  `dockerTools.buildLayeredImage` from nixpkgs' `vaultwarden` package. There is
  no registry to trust, the build is reproducible, and the version is pinned to
  whatever your nixpkgs provides.

- **nginx terminates TLS, proxies loopback.** The container binds a loopback
  port; nginx does HTTPS and reverse-proxies to `127.0.0.1`. **Websockets are
  left on** (`proxyWebsockets = true`) — without them, live vault sync between
  clients stops working.

- **`--network=host`.** The container binds `port` directly and nginx reaches it
  on loopback with no port-mapping layer in between. Because the container shares
  the host network namespace, `listenAddress` is a **host-wide** bind — it
  defaults to `127.0.0.1` so the plaintext vault port is never exposed off-box.
  The raw port speaks unencrypted HTTP; only nginx (HTTPS) should face the
  network. Do not set `listenAddress = "0.0.0.0"` unless you accept serving the
  vault API in cleartext on every interface and bypassing TLS.

## The trap worth remembering

Vaultwarden takes optional secrets (admin token, SMTP credentials, etc.) from an
environment file. podman's `environmentFiles` **fails the whole unit if the file
does not exist**. So the service's `preStart` `touch`-es `${dataDir}/env` before
start (an empty file is perfectly valid) and reclaims ownership of `dataDir`.
Put any secrets you need into that file as `KEY=value` lines — for example:

```
ADMIN_TOKEN=<argon2-hash-or-token>
SMTP_HOST=smtp.example.com
SMTP_FROM=vault@example.com
```

Because the vault database lives on a host bind-mount owned by a fixed uid, the
service user needs a **stable numeric uid/gid**. That is why `uid`/`gid` are
plain integers rather than dynamically allocated — the container runs as that
numeric id and must match the on-disk ownership.

## Usage

```nix
{
  imports = [ ./vaultwarden-gvisor-sandbox ];

  services.vaultwardenSandbox = {
    enable   = true;
    domain   = "vault.example.com";
    acmeHost = "vault.example.com";
  };

  # You provision the certificate yourself:
  security.acme.certs."vault.example.com" = { /* ... */ };
}
```

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `domain` | *(required)* | Public HTTPS domain; also passed to Vaultwarden as `DOMAIN`. |
| `acmeHost` | *(required)* | Name of the `security.acme` cert to serve (`useACMEHost`). |
| `dataDir` | `/var/lib/vaultwarden` | Vault database + env file location on the host. |
| `port` | `8222` | Loopback port the container binds and nginx proxies to. |
| `listenAddress` | `127.0.0.1` | Address the container binds (`ROCKET_ADDRESS`). Loopback-only by default; see the warning below before changing it. |
| `uid` / `gid` | `8222` | Stable numeric id owning `dataDir` and running the container. |
| `signupsAllowed` | `false` | Whether open registration is permitted (`SIGNUPS_ALLOWED`). |

## Caveats

- You must provision the TLS certificate separately (`security.acme.certs.<acmeHost>`);
  this module only references it via `useACMEHost`. The module enables `services.nginx`
  itself, but it does not manage ACME accounts, DNS, or firewall (open 80/443 yourself).
- gVisor adds a syscall-interception layer; there is a small runtime overhead
  and a few exotic syscalls behave differently. Vaultwarden works fine under it.
- **`--network=host` bypasses gVisor's user-space network stack (netstack).**
  The container shares the host network namespace, so gVisor's syscall
  sandboxing still applies but its network isolation dimension does not — a
  network-facing compromise reaches the host network stack directly. This is a
  deliberate tradeoff for the zero-port-mapping loopback bind; if you want the
  stronger netstack isolation, drop `--network=host` and add an explicit port
  map instead (at some compat cost).
- If you already register a gVisor runtime elsewhere in your configuration,
  remove the runtime-registration block to avoid defining `runsc-host` twice.
- Back up `dataDir` — it holds the SQLite database and attachments.
