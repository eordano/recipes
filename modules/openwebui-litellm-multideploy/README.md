# openwebui-litellm-multideploy

A single NixOS module that runs [Open WebUI](https://github.com/open-webui/open-webui)
in front of an OpenAI-compatible backend (e.g. [LiteLLM](https://github.com/BerriAI/litellm)),
behind an nginx TLS vhost — and lets you pick **one of three interchangeable
runtimes** from the same option set:

| `deploymentMethod` | Runtime |
|--------------------|---------|
| `docker` (default) | OCI container via `virtualisation.oci-containers` |
| `nixos-container`  | declarative NixOS container on a private link |
| `systemd`          | native systemd service (uses `pkgs.open-webui`) |

The host-side user/group, the `dataDir` layout (`data/`, `cache/`, `static/`,
`vector_db/`), and the nginx vhost are shared across all three. Only the runtime
wrapper and the env-var plumbing differ.

## Why it exists

Open WebUI is easy to run once and annoying to run *portably*: the container and
the native package want their state, ports, and reverse proxy wired up slightly
differently, and the differences are exactly where things break silently. This
module encodes one config surface and three vetted backends so you can switch
runtime without re-deriving the vhost, the persistence layout, or the security
sandbox — and it bakes in the traps below so you don't rediscover them.

## The traps this encodes

### 1. Do not re-set the `Host` header in nginx

The `/` location intentionally **omits** `proxy_set_header Host`.
`recommendedProxySettings` already forwards `Host`; adding a second one sends a
duplicate `Host` header, and uvicorn (Open WebUI's server) rejects the request
with `400 "Invalid HTTP request received"`. The long timeouts, `proxy_buffering
off`, and `client_max_body_size 100M` in that block are deliberate — they're for
streamed chat responses and file uploads.

### 2. Under docker / nixos-container, your RAG vector store is not persisted

`CHROMA_DATA_PATH` and `STATIC_DIR` point at `dataDir/vector_db` and
`dataDir/static`, but the `docker` and `nixos-container` methods bind-mount only
`data/` and `cache/`. So under those two methods the ChromaDB vector store and
static assets actually live **inside the container filesystem** and are lost on
recreate. Only the `systemd` method marks the whole tree writable and persists
everything. If you use docker/nixos-container and rely on RAG, add mounts for
`vector_db/` and `static/`.

### 3. Eight of the typed options are decorative

`embeddingEngine`, `embeddingModel`, `enableWebSearch`, `webSearchEngine`,
`enableImageGeneration`, `enableAudioTranscription`, and
`observability.{serviceName,enableMetrics}` are **declared but never referenced**
in the config — setting them does nothing. They're kept for documentation/compat.
Drive the real features through `extraEnvironment`, using Open WebUI's own env
vars (e.g. `ENABLE_RAG_WEB_SEARCH`, `RAG_WEB_SEARCH_ENGINE`, `ENABLE_OLLAMA_API`,
`AUDIO_STT_*`, OAuth vars, …). `extraEnvironment` merges **last**, so it also
overrides any default this module sets.

The security-relevant `enableSignup` and `defaultUserRole` options **are** wired
(to `ENABLE_SIGNUP` / `DEFAULT_USER_ROLE`): set `enableSignup = false` to actually
close self-service registration. You can still override them via `extraEnvironment`.

The one observability field that *is* wired is `observability.otlpEndpoint`
(only when `observability.enable = true`).

## Usage

```nix
{
  imports = [ ./openwebui-litellm-multideploy ];

  services.openwebuiMulti = {
    enable = true;
    deploymentMethod = "systemd";      # or "docker" / "nixos-container"

    domain = "chat.example.com";
    acmeHost = "example.com";           # required in practice (useACMEHost)

    # OpenAI-compatible backend (LiteLLM, vLLM router, etc.) — keep the /v1
    backendHost = "http://127.0.0.1:4000/v1";
    # backendApiKey left null -> a placeholder key is sent (fine for a keyless
    # local gateway). Never hardcode a real secret in a public config; inject it
    # through extraEnvironment / an EnvironmentFile instead.

    # Real feature config goes here, NOT through the decorative toggles:
    extraEnvironment = {
      ENABLE_SIGNUP = "false";
      DEFAULT_USER_ROLE = "pending";
      ENABLE_RAG_WEB_SEARCH = "true";
      RAG_WEB_SEARCH_ENGINE = "searxng";
      SEARXNG_QUERY_URL = "http://127.0.0.1:8888/search?q=<query>";
    };
  };
}
```

For the `docker` method the default image is already pinned to a released
version by digest; to change it, keep the digest form:

```nix
services.openwebuiMulti = {
  deploymentMethod = "docker";
  image = "ghcr.io/open-webui/open-webui:v0.10.2@sha256:9fcea9c6e32ab60b0498f3986c6cdf651ddbe61db48d2213a3d28048ddd673d4";
  # imageFile = ./open-webui.tar.gz;  # or load a locally built image
};
```

## Key options

| Option | Default | Purpose |
|--------|---------|---------|
| `deploymentMethod` | `"docker"` | `docker` \| `nixos-container` \| `systemd` |
| `domain` | `null` | nginx vhost domain (required) |
| `acmeHost` | `null` | ACME cert host (`useACMEHost`; required in practice) |
| `port` | `8080` | listen + proxy port |
| `dataDir` | `/var/lib/openwebui` | host state dir |
| `uid` / `gid` | `1316` | service user/group ids |
| `package` | `pkgs.open-webui` | package for systemd / nixos-container |
| `image` / `imageFile` | ghcr `v0.10.2@sha256:…` / `null` | OCI image for docker (digest-pinned) |
| `containerBackend` | `"docker"` | `docker` \| `podman` |
| `containerNetwork.{host,local}Address` | `192.168.201.{1,2}` | nixos-container private link |
| `containerNameservers` | `[1.1.1.1 8.8.8.8]` | resolvers inside nixos-container |
| `backendHost` | `null` | `OPENAI_API_BASE_URL` (include `/v1`) |
| `backendApiKey` | `null` | `OPENAI_API_KEY` (placeholder if null) |
| `enableSignup` | `true` | `ENABLE_SIGNUP`; set `false` to close registration |
| `defaultUserRole` | `"pending"` | `DEFAULT_USER_ROLE` (`admin` \| `user` \| `pending`) |
| `observability.{enable,otlpEndpoint}` | off / `null` | the only wired OTEL export |
| `extraEnvironment` | `{}` | the real feature escape hatch (merged last) |

## Notes / caveats

- **`docker` networking**: the port binds to `127.0.0.1` only (opened on the
  `docker0` firewall interface), and `--add-host=host.docker.internal:host-gateway`
  lets the container reach a host-local backend.
- **`nixos-container` networking**: runs on a private `192.168.201.0/24` link
  with its own resolvers, so it doesn't inherit the host's DNS.
- **Security sandbox**: the systemd/nixos-container methods run under a hardened
  unit (`ProtectSystem=strict`, `NoNewPrivileges`, a `SystemCallFilter`
  allowlist, restricted address families, etc.). `ffmpeg` is on `PATH` for
  audio/video handling.
- **Secrets**: don't put real API keys in `backendApiKey` in a checked-in
  config. Use an `*_API_KEY_FILE` env var in `extraEnvironment` pointing at a
  runtime secret, or a systemd `EnvironmentFile`.
- **Image pinning (docker method)**: the default `image` is pinned by digest to
  a released version (`v0.10.2`), so a container (re)create can never silently
  run different code. The trade-off: you must bump the tag *and* digest yourself
  to update. Do NOT switch it to a mutable tag (`:main`, `:latest`) — that
  re-pulls whatever upstream currently publishes (force-push, tag hijack,
  compromised build) with no change to your Nix config. A locally built
  `imageFile` also works.
- Requires `services.nginx` enabled with `recommendedProxySettings = true` (the
  Host-header behaviour above depends on it) and ACME configured for `acmeHost`.
```
