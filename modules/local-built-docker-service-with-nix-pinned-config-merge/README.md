# local-built-docker-service-with-nix-pinned-config-merge

A NixOS module for running a self-hosted app from a Docker image **built on the
host** (no registry, no `dockerTools`), while keeping the *security-relevant
slice* of the app's runtime JSON config reproducible in Nix — jq-merged into the
operator's hand-edited config on every start.

## The problem

You have an app that:

1. Ships as a Dockerfile in a source tree you sync onto the host yourself
   (rsync, a deploy step, a checkout) — you do **not** want to publish an image
   to a registry just to run it.
2. Keeps its runtime config as a mutable JSON file that the **operator** edits
   by hand (auth tokens, model choices, agent definitions, sessions).
3. Has a subset of that config that is **security-relevant** and must stay
   under version control — e.g. a capability / skills / tool allowlist that
   decides what the app is permitted to do.

You want (2) and (3) to coexist: operator edits survive redeploys, but the
pinned surface is re-asserted from Nix and can never silently drift.

## The insight: split ownership via a jq merge

The runtime config file has **two owners**:

- The **operator** owns the file as a whole — their hand-edits persist.
- **Nix** owns only the keys in the `pinnedConfig` option.

On every service start, an `ExecStartPre` step renders `pinnedConfig` to JSON in
the store and `jq`-merges it into the live config file, replacing only the
pinned keys and leaving everything else intact. The security-relevant surface is
therefore reproducible and version-controlled, while volatile operator state is
never clobbered.

The default `mergeFilter` (`. * $pinned[0]`) is a recursive deep merge: pinned
keys win, sibling operator keys survive. Override it for surgical control — e.g.
to authoritatively *replace* a whole subtree instead of deep-merging it:

```nix
mergeFilter = ''
  .skills = ((.skills // {}) + { allowBundled: $pinned[0].allowBundled,
                                 entries: $pinned[0].entries })
'';
```

## Traps (the reason this module exists)

- **Tag-bump-to-rebuild.** The one-shot builder skips when `imageTag` already
  exists, so redeploys are cheap — but a *code change alone rebuilds nothing*.
  You must bump `imageTag` to force a rebuild. This is deliberate (cheap
  redeploys) but bites the unaware.
- **No Dockerfile ⇒ hard fail.** The build unit refuses to start if
  `sourceDir` has no `Dockerfile`, so a forgotten source sync fails loudly
  instead of running a stale image.
- **uid/gid must match the image.** State and workspace dirs are chowned to
  `runUid`/`runGid` (default `1000`) so the in-container user can read/write
  them. If the image bakes a different uid, container writes fail with
  `EACCES` — inspect the image and set these knobs accordingly.
- **Host networking is a footgun, so it's fenced.** The default `dockerArgs`
  use `--network=host` (handy when the app must reach a loopback-only backend)
  and then drop `NET_RAW`/`NET_ADMIN` and set `no-new-privileges:true` to claw
  back part of what host networking gives away. If you don't need host
  networking, replace `dockerArgs` with a `-p` publish and a bridge network.
- **Loopback binding = no external reach.** If your app binds loopback (a
  common safe default), it's only reachable locally; front it with a
  tunnel/reverse-proxy for external access. Nothing in this module exposes it.
- **The pinned merge runs every start, including after crashes.** Because it's
  an `ExecStartPre` on a `Restart=always` service, a restart loop re-asserts the
  pinned surface each time. That's the point, but keep the merge idempotent
  (the default deep-merge is).

## Usage

```nix
{
  imports = [ ./local-built-docker-service-with-nix-pinned-config-merge ];

  services.localDockerApp = {
    enable = true;
    name = "myapp";

    # Source tree with a Dockerfile, synced onto the host out-of-band.
    sourceDir = "/srv/myapp/src";

    # Bump this to force a rebuild.
    imageTag = "myapp:local-1.0.0";

    # Command run inside the container (appended after the image tag).
    command = [
      "node" "dist/index.js" "gateway"
      "--bind" "loopback"
      "--port" "18789"
    ];

    # docker run flags: mount state/workspace, set env, pick the network.
    dockerArgs = [
      "--network=host"
      "--cap-drop=NET_RAW"
      "--cap-drop=NET_ADMIN"
      "--security-opt=no-new-privileges:true"
      "--init"
      "-e" "HOME=/home/node"
      "-v" "/var/lib/myapp/state:/home/node/.myapp"
      "-v" "/var/lib/myapp/workspace:/home/node/.myapp/workspace"
    ];

    # The Nix-owned, version-controlled config surface (e.g. a capability
    # allowlist). Merged into the runtime config file on every start.
    pinnedConfig = {
      allowList = [ "read-files" "run-shell" "http-fetch" ];
      entries."http-fetch" = {
        enabled = true;
        env.BASE_URL = "https://api.example.com/v1";
      };
    };

    # Optional secrets, passed via --env-file (point at a decrypted path).
    envFile = "/run/secrets/myapp.env";
  };
}
```

### Key options

| Option | Purpose |
| --- | --- |
| `name` | Short identifier (default `localapp`) used to name the units, the `/var/lib/<name>` tree and the rendered store files. Change it to run more than one instance. |
| `sourceDir` | Docker build context on the host (must contain a `Dockerfile`). |
| `imageTag` | Tag of the locally built image. **Bump to rebuild.** |
| `command` | Command + args run inside the container. |
| `dockerArgs` | Extra `docker run` flags (volumes, env, network, security). |
| `pinnedConfig` | Attrset Nix owns; rendered to JSON and merged in each start. |
| `mergeFilter` | jq filter controlling how the pinned surface is merged. |
| `configFileName` | Basename of the runtime JSON config under `stateDir`. |
| `stateDir` / `workspaceDir` | Host bind-mount dirs (created + chowned). |
| `runUid` / `runGid` | In-container uid/gid; state dirs are chowned to these — must match the image (default `1000`). |
| `containerName` | Name of the running container, used for `rm`/`stop` (defaults to `name`). |
| `envFile` | Optional `--env-file` path for secrets. |
| `buildTimeout` | `TimeoutStartSec` for the one-shot build unit (default `60min`). |

## Caveats

- **Registry-free by design.** Source arrives out-of-band; the module never
  fetches from the network. If you want reproducible *builds*, consider
  `pkgs.dockerTools.buildImage` instead — this module targets the case where
  you have an existing Dockerfile you'd rather not port.
- **`pinnedConfig` should hold only the reproducibility-critical keys.** Put
  volatile operator state (tokens, sessions) outside it, or the merge will keep
  stomping it.
- **Never put secrets in `pinnedConfig`.** It is serialized to a JSON file in
  the **world-readable Nix store** (mode `0444`), so any local user can read it.
  Keep API keys, tokens, and passwords out of it — route them through `envFile`
  (a runtime path such as `/run/secrets/...`), which is the only secret-bearing
  input this module reads at runtime rather than baking into the store.
- **The config file lives inside `stateDir` and is chmod `600`.** If your image
  reads it from a different path, adjust the bind-mount in `dockerArgs` and
  `configFileName` so both point at the same file.
- **An empty allowlist may mean "allow everything" in some apps**, not "allow
  nothing" — check your app's semantics before shipping an empty `pinnedConfig`.
- **It turns Docker on for you.** Enabling the module sets
  `virtualisation.docker.enable` and `virtualisation.docker.autoPrune.enable`.
  The pruner only reaps dangling images, so the tagged build survives — but old
  tags you bump away from are yours to clean up.
