# private-nix-cache-substituter

Register a self-hosted binary cache as a `substituter` on your NixOS
hosts — but gate it behind a `pathExists` check on the cache's public-key
file, so a host that hasn't received the key yet **silently skips the cache
instead of failing to evaluate**.

This is the client-side counterpart to a signed binary cache (the server
that exposes a store over HTTPS). Here we're on the consuming end: telling a
fleet of hosts to pull pre-built paths from that cache.

## The problem it solves

To pull from a private binary cache, a client needs two things:

1. the substituter URL (`https://cache.example.com`), and
2. the cache's **public signing key** in `nix.settings.trusted-public-keys`.

Nix clients run with `require-sigs = true` by default and will refuse NARs
from a substituter unless each narinfo is signed by a key they trust. So the
public key has to be on the client.

The URL is static config you can commit. The key file, however, usually
arrives out-of-band — decrypted by agenix / sops-nix, dropped by a
provisioning step, or copied during bootstrap — and **may not be present yet**
on a freshly installed or not-yet-provisioned host.

## The trap

The obvious implementation reads the key inline:

```nix
nix.settings.trusted-public-keys = [
  (builtins.readFile /run/secrets/cache-key.pub)
];
```

`builtins.readFile` runs at **evaluation** time. On any host where the key
file isn't there yet, evaluation **aborts** — you can't even build the system
closure until the secret lands. That's backwards: the cache is an
optimization; its absence should never block you from building the machine
that's supposed to receive the key in the first place. It's a
chicken-and-egg lock-up during bootstrap.

## The fix

Compute a `keyExists` guard with `builtins.pathExists` and wrap the whole
config block in `lib.mkIf`:

```nix
keyExists = cfg.keyFile != null && builtins.pathExists cfg.keyFile;
...
config = lib.mkIf (cfg.enable && keyExists) {
  nix.settings.substituters        = [ "https://${cfg.domain}" ];
  nix.settings.trusted-public-keys = [ (lib.removeSuffix "\n" (builtins.readFile cfg.keyFile)) ];
};
```

A host without the key evaluates cleanly and just doesn't use this cache
(it builds from source or from other substituters). Once the key is
provisioned, the next evaluation picks it up automatically — no manual
toggle.

`lib.removeSuffix "\n"` trims the trailing newline the key file almost
certainly has, so the trusted-key string matches exactly.

## Usage

```nix
{
  imports = [ ./private-nix-cache-substituter ];

  modules.nixCacheSubstituter = {
    enable  = true;
    domain  = "cache.example.com";
    # keyFile defaults to /run/secrets/<domain>-key.pub — override if needed:
    # keyFile = config.age.secrets."cache-key".path;
  };
}
```

### Options

| Option    | Default                              | Meaning |
|-----------|--------------------------------------|---------|
| `enable`  | `false`                              | Turn the module on. |
| `domain`  | *(required)*                         | Cache host; becomes `https://<domain>` and the default key-file name. |
| `keyFile` | `/run/secrets/<domain>-key.pub`      | Path to the public-key file (`<name>:<base64>`). `null` force-skips. Missing file = module is a no-op. |

The `.pub` file holds one line as produced by:

```sh
nix-store --generate-binary-cache-key cache.example.com-1 \
  cache-priv-key.pem cache-pub-key.pem
```

Publish/ship `cache-pub-key.pem` (that's the `keyFile`); keep
`cache-priv-key.pem` on the cache host to sign NARs.

## Caveats

- **Evaluation-time path.** `pathExists` and `readFile` see the path *as the
  evaluator sees it*. `keyFile` must be readable during evaluation — a
  checked-in `.pub`, or a secret already decrypted onto disk. A path that
  only appears at activation/runtime will read as "missing" and the cache
  will silently stay off. Provision the key before (or as part of) the same
  evaluation you expect to use it.

- **Pure-eval / flakes.** Under `--pure-eval`, absolute paths outside the
  flake may not be readable at eval time. If you build flakes purely, either
  keep the key file inside the flake source tree or accept that the guard
  reads as "missing" (which fails safe — no cache, no error).

- **Silent by design.** The whole point is that a missing key produces no
  error. If you *expect* the cache and it isn't being used, check that the
  key file actually exists at the evaluated path — the failure mode is a
  quiet cache miss, not a loud one.
