# headplane-secret-splice

A NixOS module for [Headplane](https://github.com/tale/headplane) -- the web UI
for [Headscale](https://github.com/juanfont/headscale) -- that solves three traps
a plain `settings`-renders-a-YAML-file module can't.

## The problem

Headplane wants a `config.yaml` that contains live secrets: a session cookie
secret, an OIDC client secret, and a Headscale API key. The obvious NixOS
approach -- put them in a `settings` option and let Nix render the YAML -- is
wrong, and Headplane's own operational quirks make it worse:

1. **A Nix-rendered config is world-readable in `/nix/store`.** Anything Nix
   writes to the store is readable by every user on the machine. Secrets must
   not be in the store, so they cannot be part of the rendered `settings`.

2. **Headplane hardcodes its paths.** It reads `/etc/headplane/config.yaml` and
   stores state under `/var/lib/headplane` unconditionally -- these are not
   configurable in the app, so the module has to write to them directly.

3. **Headplane reads a *copy* of Headscale's config, not the live file.** It
   won't notice when Headscale's config or DNS `extra_records.json` change, so
   something external has to poke it.

## The pattern

- **Splice secrets at boot, as root, with `yq`.** Nix renders the
  secret-free config to the store. A `headplane-config-generator` root oneshot
  copies that into `/etc/headplane/config.yaml` and uses `yq eval -i` with
  `strenv(...)` to inject each secret read from its file. The secrets exist only
  in root-readable files and in the final `0750` config dir -- never in the
  store. Using `strenv` (an environment variable) rather than a shell
  interpolation keeps the secret out of the process argument list and handles
  arbitrary characters safely.

- **Write to the hardcoded paths and lock them down.** The generator creates
  `/etc/headplane` (`0750`) and `/var/lib/headplane` (`0700`), owned by the
  service user, and seeds a `0600` `users.json`.

- **Sync + watch to force reloads.** `headplane-sync-headscale-config` copies
  Headscale's rebuild-varying store config to a stable
  `/var/lib/headscale/config.yaml`. A `systemd.path` unit watches that file and
  `extra_records.json`; on change it triggers `headplane-reload`, which restarts
  Headplane. Watching the stable copy (not the store path, which changes name
  every rebuild) is what makes the path unit reliable.

- **Ordering.** `headplane.service` runs `after` both the sync and the generator
  oneshots (and `headscale.service`), so it always starts against a fully
  spliced config and a fresh headscale copy. The oneshots are `partOf`
  headscale so they re-run when headscale restarts.

It also `disabledModules` the upstream `services/networking/headplane.nix` so
there's no conflict.

## Usage

```nix
{
  imports = [ ./modules/headplane-secret-splice ];

  services.headplane = {
    enable = true;

    # Point these at whatever secrets manager you use -- agenix, sops-nix,
    # a systemd credential, or a plain root-only file. Each is optional;
    # a null one is simply not spliced.
    secretFiles = {
      cookieSecret     = "/run/agenix/headplane-cookie-secret";
      oidcClientSecret = "/run/agenix/headplane-oidc-secret";
      headscaleApiKey  = "/run/agenix/headscale-api-key";
    };

    # Secret-free config -- everything except the three spliced keys.
    # See https://github.com/tale/headplane/blob/main/config.example.yaml
    settings = {
      server = {
        host = "127.0.0.1";
        port = 3000;
      };
      headscale.url = "https://headscale.example.com";
      oidc = {
        issuer = "https://sso.example.com/realms/main";
        client_id = "headplane";
        # client_secret is spliced in -- do NOT put it here.
      };
    };
  };
}
```

By default the service runs as `config.services.headscale.user` / `.group` so it
can read Headscale's state; override `services.headplane.user` / `.group` if
your setup differs.

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `package` | `pkgs.headplane` | Headplane package to run. |
| `user` / `group` | headscale's user/group | Service identity; needs read access to headscale state. |
| `settings` | `{ }` | Freeform YAML config. **No secrets here.** |
| `secretFiles.cookieSecret` | `null` | File -> `.server.cookie_secret`. |
| `secretFiles.oidcClientSecret` | `null` | File -> `.oidc.client_secret`. |
| `secretFiles.headscaleApiKey` | `null` | File -> `.headscale.api_key`. |

## Caveats

- Requires a working `services.headscale` with a `configFile` on the same host --
  the module reads it and runs as its user by default.
- The secret files must be readable by root at boot (the generator runs before
  Headplane). If your secrets manager decrypts late, order the generator
  `after` its unit.
- `/etc/headplane` and `/var/lib/headplane` are Headplane's, not yours -- don't
  expect to relocate them without patching upstream.
- The path watcher restarts (not reloads) Headplane on every change; expect a
  brief blip when Headscale's config or DNS records change.
