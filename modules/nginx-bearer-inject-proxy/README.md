# nginx-bearer-inject-proxy

A NixOS module for the reverse-proxy pattern where nginx adds an
`Authorization: Bearer <key>` header the client never sends and never sees, and
the key is a secret. The header is injected from an `include` file rendered into
`/run` at boot -- so the key never touches the world-readable Nix store. It
supports a **real** mode (inject a live secret bearer) and a
**passthrough/cosmetic** mode (inject a self-generated throwaway token for
upstreams that want *an* Authorization header but do not validate it).

## The problem

You are fronting some upstream API with nginx, and the upstream expects a bearer
token. You want browsers / internal clients to reach it through your proxy
without ever handling that token themselves -- so nginx has to attach it on the
way out. The one-line way to do this looks harmless:

```nix
locations."/".extraConfig = ''
  proxy_set_header Authorization "Bearer ${config.mySecret}";
'';
```

and it is a leak. `extraConfig` is interpolated into the nginx config that Nix
writes to `/nix/store/...-nginx.conf`, and the store is **world-readable**: mode
`0755`, every local user can `cat` it, and it propagates into every build
closure, binary cache, and backup. Any secret you interpolate into a NixOS
module string ends up there in cleartext. Grepping the store for `Bearer ` finds
these instantly.

## The approach

Keep the secret out of the store by rendering the `proxy_set_header` line at
runtime, into a file nginx `include`s:

- A oneshot systemd service (`nginx-bearer-inject`) runs as root before nginx
  starts. It reads the secret from a file on disk (agenix / sops-nix / a
  systemd credential -- whatever you already use), and writes
  `proxy_set_header Authorization "Bearer <key>";` to
  `/run/nginx-snippets/bearer-<name>.conf`.
- The write is atomic (temp file + `mv`) so a config reload never reads a
  half-written include, and the file is `chmod 0640` / `chgrp <nginx group>` --
  tighter than the world-readable store it replaces.
- Your vhost location just does `include <that path>;`. The module exposes the
  path as a read-only option so you never hand-type it.
- Ordering is wired both ways: `nginx-bearer-inject` runs `before` nginx, and
  nginx `wants`/`after` it, so the include always exists when nginx loads
  config.

`/run` is tmpfs: not in the store, not in any closure, gone on reboot and
re-rendered on the next. nginx reads `include` files at config-load time as the
master process (root), so the rendered snippet only ever needs to be
root-readable -- which is why `0640 root:nginx` is safe and world-readable is
not.

**Passthrough mode** renders the same shape from a self-generated 32-char token
instead of a secret file. Use it when the upstream requires the header to be
present but does not check it (or auth really happens elsewhere), so the real
and cosmetic paths are byte-identical from nginx's side without provisioning a
real secret.

### Usage

```nix
{
  imports = [ ./nginx-bearer-inject-proxy ];

  # 1. However you already manage the secret (agenix shown):
  age.secrets.upstream-api-key = {
    rekeyFile = ./secrets/upstream-api-key.age;
    mode = "0400";
    owner = "root";
  };

  # 2. Declare the injector(s):
  services.nginxBearerInject.injectors = {
    upstream = {
      mode = "real";
      secretFile = config.age.secrets.upstream-api-key.path;
      keyPrefix = "sk-";           # -> Authorization: Bearer sk-<key>
    };
    # An upstream that only wants the header to exist:
    scratch = {
      mode = "passthrough";
    };
  };

  # 3. Reference the rendered include from a vhost:
  services.nginx.virtualHosts."api.example.com" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:8080";
      extraConfig = ''
        include ${config.services.nginxBearerInject.injectors.upstream.snippetPath};
      '';
    };
  };
}
```

### Companion pattern: register the key at the upstream

`example-register-key.nix` sketches the mirror-image concern: making that key
*exist* at the upstream. Many gateways mint virtual API keys behind a
master/admin key; the file is a oneshot-service builder that waits for the
upstream to be healthy and then idempotently registers the same key value your
proxy injects. It is a secondary example -- adapt its HTTP contract to your
provisioning API; the reusable shape is the ordering + health-wait + idempotency.

The one part of that example that is *not* free to rewrite is how it hands
secrets to `curl`. The admin token and the key never go on argv (`-H "... Bearer
$ADMIN_KEY"`) and never go in a URL query string. Instead the admin token and
lookup headers are passed through `--config -` (a heredoc on stdin), and request
bodies go through a `0600` temp file referenced from that config. This keeps both
secrets out of `ps` / `/proc/<pid>/cmdline` and out of the upstream's access logs
(which record query strings). If you adapt the endpoints, keep the header/body
plumbing -- "simplifying" it to `-H` or a query parameter re-leaks the secret.

## Options

`services.nginxBearerInject`:

| Option | Default | Effect |
| --- | --- | --- |
| `injectors.<name>.mode` | `"real"` | `"real"` injects `secretFile`; `"passthrough"` injects a self-generated cosmetic token. |
| `injectors.<name>.secretFile` | `null` | Runtime path to the secret (a `.path`, not the value). Required in real mode. |
| `injectors.<name>.keyPrefix` | `""` | Literal prefix inside the header value, e.g. `"sk-"`. |
| `injectors.<name>.snippetMode` | `"0640"` | Permission bits on the rendered `/run` include. |
| `injectors.<name>.snippetPath` | computed, read-only | Path to `include` from your vhost. |
| `nginxGroup` | `services.nginx.group` or `"nginx"` | Group that owns the rendered snippets. |

## Traps and caveats

- **Never put the key in `extraConfig` directly.** That is the entire reason
  this module exists; see The problem. If you find yourself interpolating a
  secret into any `services.*` string option, stop -- it goes to the store.

- **`secretFile` is a path, not a value.** Pass `config.age.secrets.foo.path`
  (a `/run/agenix/...` runtime path), never the decrypted contents. Passing the
  value re-creates the exact leak.

- **Rotation needs a nudge.** The snippet is rendered once, at service start. If
  the underlying secret rotates, restart `nginx-bearer-inject.service` and then
  reload nginx (`systemctl restart nginx-bearer-inject && systemctl reload
  nginx`). nginx does not re-read includes on its own.

- **The snippet must exist before nginx loads config.** The module wires the
  ordering for you. If you render includes some other way, remember nginx will
  refuse to start (or fail a reload) if an `include`d file is missing.

- **`/run` is tmpfs and cleared on reboot.** That is a feature -- the secret is
  never persisted outside its source -- but it means the render service must run
  every boot (it is `wantedBy = multi-user.target`). Don't move the snippet dir
  onto persistent storage to "fix" a perceived problem; you would be persisting
  the plaintext.

- **`chgrp` is best-effort.** If you set `nginxGroup` to a group that does not
  exist yet, the `chgrp` is tolerated (`|| true`) and the file stays
  `root:root` -- still not world-readable, but confirm nginx (master, root) can
  read it. With the default group this is a non-issue.

- **Passthrough tokens are cosmetic only.** They are a fresh random string each
  boot and are not registered anywhere. If your upstream actually validates the
  header, use `"real"` mode with a provisioned key (and see the register-key
  companion), not passthrough.
