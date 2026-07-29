# jitsi-meet-keycloak-oidc-overlay

A Nixpkgs overlay that bolts a **Keycloak / OIDC SSO adapter** into
`jitsi-meet`'s static output — and works around a `qemu-user` webpack crash so
the overlay still evaluates on non-x86_64 builders (e.g. aarch64).

## The problem

You want Jitsi Meet to authenticate through Keycloak (OIDC / SSO) instead of
its built-in auth. Adapters exist that do this by dropping a few extra static
HTML/TS files next to jitsi-meet's own assets plus a small side-car service.
The Nix-friendly way to install those extra files is `overrideAttrs` on the
`jitsi-meet` derivation, appending them in a late install phase.

Two traps make this trickier than it looks.

### Trap 1 — you can just append; don't rebuild

`jitsi-meet`'s output is **platform-independent static web assets**. The OIDC
adapter is likewise just more static files. So there is no need to rebuild the
(expensive, fragile) webpack bundle — copying the extra files into `$out` in an
appended `installPhase` is enough.

### Trap 2 — the webpack build dies under qemu-user emulation

If you build `jitsi-meet` for a foreign architecture through `qemu-user`
emulation (a common setup: an aarch64 builder producing an x86_64 closure, or
vice-versa), the webpack build **crashes**. V8's JIT emits an instruction the
user-mode emulator can't translate and the process dies with:

```
uncaught target signal 4 (Illegal instruction)
```

Because the output is arch-independent, the fix is to **not emulate the build at
all**. When the host platform isn't the native one, the overlay re-imports
nixpkgs (pinned via `prev.path`) *for the native system* and reuses that
natively-built `jitsi-meet`, then bolts the adapter onto it. The static files it
produces are valid on the current host regardless.

## Usage

This is a **curried overlay** — call `import` with your arguments first, then
pass the result to `nixpkgs.overlays`:

```nix
nixpkgs.overlays = [
  (import ./jitsi-meet-keycloak-oidc-overlay {
    # Required: path to your OIDC adapter source tree (see layout below).
    adapterSrc = ./my-jitsi-oidc-adapter;

    # Optional: the arch you can build jitsi-meet natively for.
    # Defaults to "x86_64-linux".
    nativeSystem = "x86_64-linux";
  })
];
```

### `adapterSrc` layout

The overlay merges your tree into the jitsi-meet output like this:

| Source                        | Destination           |
| ----------------------------- | --------------------- |
| `${adapterSrc}/*.ts`          | `$out/oidc-adapter/`  |
| `${adapterSrc}/jitsi-meet/*`  | `$out/` (merged)      |

Point `adapterSrc` at a checkout of an upstream jitsi ⇄ Keycloak OIDC adapter
(several open-source ones exist) or your own fork. It is deliberately a
*parameter* rather than a vendored copy, so you supply — and license — the
third-party adapter code yourself.

### The side-car service

Most such adapters run a small server (often a Deno or Node process) that mints
the JWT Jitsi expects from the Keycloak session. That service is **out of scope
for this overlay** (the overlay only installs the static assets), but two things
are worth flagging because they bite people:

- **Certificates.** Adapters frequently ship a *test* launch command with a
  "trust any certificate" flag (e.g. `--unsafely-ignore-certificate-errors`) so
  they work against a Keycloak with a self-signed cert. **Flip this off** for
  production once Keycloak presents a trusted certificate.
- **Configuration is environment-driven.** Adapter config (Keycloak origin,
  realm, client id, JWT app id/secret, listen host/port) is typically read from
  environment variables with placeholder defaults. Set every value explicitly;
  never ship the upstream example defaults.

## Caveats

- `nativeSystem` must be an architecture your builder can produce **natively**
  (native builder or a binary cache serving it). If it can't, you've only moved
  the emulation problem, not solved it.
- The overlay pins the native nixpkgs to `prev.path`, i.e. the *same* nixpkgs
  the overlay is applied to — so both arches stay on one revision.
- This installs assets only. Wiring up the OIDC side-car service, Keycloak
  client, and Jitsi config is left to your NixOS configuration.
