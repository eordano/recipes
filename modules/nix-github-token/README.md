# nix-github-token

A tiny NixOS module that hands Nix an authenticated GitHub personal access
token (PAT) so flake and `fetchFromGitHub` fetches stop hitting github.com's
rate limit — without ever writing the token into the Nix store.

## The problem

Unauthenticated github.com access is throttled to **60 requests/hour per IP**.
A machine that resolves many flake inputs or `fetchFromGitHub` sources burns
through that almost instantly, and then evaluations and builds stall on
`API rate limit exceeded` errors. An authenticated PAT raises the limit to
**5000/hour**. This bites hardest on agent/CI/build hosts that fetch a lot.

The fix Nix documents is the `access-tokens` setting:

```
access-tokens = github.com=ghp_xxx...
```

But a naive way to set that has two failure modes this module avoids.

## The two traps

**1. Don't put the token in `nix.conf`.**
`/etc/nix/nix.conf` is generated into the Nix store and is world-readable.
`access-tokens` is a secret. Setting it via `nix.settings.access-tokens`
leaks the PAT to every user on the box and into the store. Instead, this
module writes the `access-tokens` line into a file under `/run` (tmpfs,
`0440`) at activation time and never lets the secret touch the store.

**2. Use `!include`, not `include`.**
The token file under `/run` does not exist yet on a fresh boot — the
activation script hasn't run, and your secret manager may not have decrypted
the token. A plain `include` of a missing file makes *every* `nix` invocation
fail. The bang form, `!include`, is the optional include: Nix silently
ignores it when the file is absent, so you degrade gracefully to
unauthenticated (rate-limited) fetches instead of a hard error.

## Usage

Import the module and point `tokenFile` at a file that will contain the raw
PAT at runtime. The module is secret-manager agnostic — anything that produces
a readable file works: agenix, sops-nix, a systemd credential, or a manually
placed `0400` file.

```nix
{
  imports = [ ./modules/nix-github-token ];

  services.nix-github-token = {
    enable = true;
    tokenFile = "/run/secrets/github-pat";   # produced by your secret system
    # activationDeps = [ "agenix" ];          # order after the secret is placed
  };
}
```

### With agenix

```nix
age.secrets.github-pat = {
  rekeyFile = ./secrets/github-pat.age;   # or `file =` for plain agenix
  mode = "0400";
};

services.nix-github-token = {
  enable = true;
  tokenFile = config.age.secrets.github-pat.path;
  activationDeps = [ "agenix" ];   # run after agenix decrypts
};
```

### With sops-nix

```nix
sops.secrets.github-pat = { };

services.nix-github-token = {
  enable = true;
  tokenFile = config.sops.secrets.github-pat.path;
  activationDeps = [ "setupSecrets" ];
};
```

## Options

| Option           | Default                          | Purpose                                                                 |
| ---------------- | -------------------------------- | ----------------------------------------------------------------------- |
| `enable`         | `false`                          | Turn the module on.                                                      |
| `tokenFile`      | *(required)*                     | Path to the file holding the raw PAT at runtime.                        |
| `host`           | `"github.com"`                   | Auth host. Set to your GitHub Enterprise host to authenticate there.    |
| `runtimeFile`    | `"/run/nix-github-access-tokens"`| tmpfs path the `access-tokens` line is written to and `!include`d from. |
| `activationDeps` | `[ ]`                            | Activation steps to order *after* (whatever decrypts/places the token). |

## Caveats

- **Order the activation script after your secret.** If `activationDeps` is
  empty and the token isn't in place yet at activation time, the `/run` file
  simply isn't written that cycle — you fall back to unauthenticated fetches
  until the next activation. Set `activationDeps` to close that gap.
- **Rotate the PAT before it expires.** GitHub PATs expire; a dead token gives
  you `Bad credentials` and, effectively, unauthenticated rate limits again.
  Encode the expiry in your secret's filename if that helps you remember.
- **Scope the token minimally.** For public-repo fetches a fine-grained token
  with read-only public access is enough; it does not need repo write scopes.
- The token file under `/run` is `0440`. Only grant it to trusted local users;
  anyone who can read it can read the PAT.
