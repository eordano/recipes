# jupyterlab-cuda-sandboxed

A NixOS module that runs a **GPU/CUDA JupyterLab** as a native systemd service
under a **strict systemd sandbox** — the full lockdown treatment, minus exactly
the two knobs CUDA cannot live without.

Applies to any PyTorch / Triton / `torch.compile` / hand-written-CUDA-extension
workload, not just notebooks. The sandbox pattern is the reusable part.

## The problem

You want a long-lived GPU service (a notebook, an inference server, a training
box) locked down like any other systemd unit: `ProtectSystem=strict`,
`PrivateDevices`, `MemoryDenyWriteExecute`, minimal capabilities. But CUDA
breaks under a naive lockdown in two non-obvious ways, and the failures are
opaque — an import error deep in `torch`, or a `mmap` that returns `EPERM`.

## The two traps

### 1. CUDA forces two sandbox knobs open

- **`MemoryDenyWriteExecute = false`** — Triton, TorchInductor, and any
  JIT-compiled kernel map memory that is **writable and executable at the same
  time**. `MemoryDenyWriteExecute=true` (the hardened default) kills that with
  `EPERM`. It must be off.
- **`PrivateDevices = false`** — the framework needs the **raw `/dev/nvidia*`
  device nodes**. `PrivateDevices=true` hides them.

Turning both off sounds like giving up on the sandbox. It isn't — you claw the
device exposure back:

- **`DevicePolicy = "closed"`** denies every device node, then a **per-index
  NVIDIA whitelist** hands back exactly the control/UVM/modeset/caps nodes plus
  one `/dev/nvidiaN` per GPU you asked for. `cudaDevices = "0"` sees GPU 0 and
  nothing else; `CUDA_VISIBLE_DEVICES` mirrors it as belt-and-suspenders.
- Everything else stays on: `NoNewPrivileges`, `ProtectSystem=strict`,
  `ProtectHome`, `RestrictNamespaces`, `ProtectKernelTunables/Modules/Logs`,
  `RestrictSUIDSGID`, `ProtectProc=invisible`, `UMask=0077`, and a capability
  set pared to just `CAP_SYS_NICE`.

### 2. `ProtectSystem=strict` makes every framework cache blow up

With a read-only root, the **only** writable location is `ReadWritePaths`
(the single `dataDir`). But every ML framework wants to write a cache
*somewhere*, and by default those somewheres are scattered across `$HOME` and
`/tmp` in ways that trip the sandbox on first import or first compile.

The fix is to redirect **all** of them under `dataDir` via env vars, and
pre-create the tree with `tmpfiles` so nothing races a missing directory:

| Cache | Env var |
|-------|---------|
| HuggingFace home | `HF_HOME` |
| Transformers | `TRANSFORMERS_CACHE` |
| HF hub | `HF_HUB_CACHE` |
| XDG (catch-all) | `XDG_CACHE_HOME` |
| Triton | `TRITON_CACHE_DIR` |
| TorchInductor | `TORCHINDUCTOR_CACHE_DIR` |

Miss one and you get an obscure write-permission error the first time a cell
touches that framework.

### Bonus: compiling from inside a cell

For `torch.compile` / Triton / custom CUDA extensions to build **at notebook
runtime**, the compiler toolchain has to be reachable: `gcc`, `ninja`,
`pybind11` headers (`CPLUS_INCLUDE_PATH`), the `cudatoolkit` (`CUDA_HOME`), and
the userspace driver (`LD_LIBRARY_PATH=/run/opengl-driver/lib`, brought into the
strict mount namespace via `BindReadOnlyPaths`). All are wired up here.

## Access control — read this

The notebook runs with **no token and no password**, bound to **loopback
(`127.0.0.1`)**. That is deliberate: **the nginx TLS vhost is the sole
authenticator.** The module *asserts* that `domain` and `acmeHost` are set
before it will enable, precisely so you can't accidentally stand up an
unauthenticated notebook.

The loopback bind means the raw tokenless port is unreachable off-box no matter
what the firewall does — a stranger cannot hit it directly even on a
multi-homed or cloud host with the NixOS firewall disabled. **Never proxy or
port-forward it onto an untrusted network.** Authorization is the TLS proxy —
nothing else. Put the vhost behind whatever real auth (mTLS, SSO, VPN/tailnet)
your environment uses.

### Security notes

- **Cross-origin defenses stay on.** The server runs with the XSRF check
  enabled and `--ServerApp.allow_origin` scoped to `https://<domain>` — on a
  token-less notebook these are the last line of defense against a malicious
  page in the operator's browser driving the loopback port via CSRF or
  DNS-rebinding. Don't add `--ServerApp.disable_check_xsrf=True` or widen
  `allow_origin` to `*`; if a non-browser client trips the XSRF check, have it
  carry the `_xsrf` cookie/token instead.

The proxy also sets `proxy_read_timeout 86400` so a single cell can run for a
full day without nginx tearing the connection down, and `proxyWebsockets` to
carry the kernel comm channel.

## Usage

```nix
{
  imports = [ ./jupyterlab-cuda-sandboxed ];

  services.jupyterlabCuda = {
    enable   = true;
    domain   = "notebooks.example.com";
    acmeHost = "notebooks.example.com";

    # Recommended: build the Python env / torch / cudatoolkit from an unstable
    # channel so CUDA wheels stay current — and so torch resolves to the SAME
    # store closure any other CUDA services on the host use (build it once).
    cudaPkgs = inputs.nixpkgs-unstable.legacyPackages.${pkgs.system};

    cudaDevices = "0";        # or "0 1" for two GPUs
    dataDir     = "/var/lib/jupyter";
  };
}
```

### Options

| Option | Default | Notes |
|--------|---------|-------|
| `enable` | `false` | |
| `domain` | `null` | **Required.** nginx vhost — the only front-door auth. |
| `acmeHost` | `null` | **Required.** ACME cert host for the vhost. |
| `cudaPkgs` | `pkgs` | nixpkgs instance for python/torch/cudatoolkit. Point at unstable for fresh CUDA wheels + a shared closure. |
| `cudaDevices` | `"0"` | Space-separated GPU indices; drives both the device whitelist and `CUDA_VISIBLE_DEVICES`. |
| `dataDir` | `/var/lib/jupyter` | HOME, WorkingDirectory, sole writable path, cache root. |
| `port` | `8888` | Loopback port behind nginx. |
| `bindIp` | `"127.0.0.1"` | Address JupyterLab binds. Loopback so the tokenless port is unreachable off-box; only widen if you understand the exposure. |
| `user` / `group` | `jupyter` | |
| `uid` / `gid` | `1328` | Pin these if you use impermanence / stable ownership. |
| `extraPythonPackages` | `ps: [ ]` | Function of the python package set, appended to the notebook env (e.g. `ps: [ ps.geopandas ]`). |
| `extraPath` | `[ ]` | Extra packages appended to the service `PATH` (e.g. more `jupyterlab-lsp` language servers). |

## Caveats

- **`cudaPkgs` is not optional in spirit.** The default (`pkgs`) works only if
  your pinned nixpkgs already has CUDA-enabled torch you're happy with.
  Otherwise point it at an unstable channel. Sharing one `cudaPkgs` across every
  CUDA service on the host avoids compiling PyTorch once per service.
- **NVIDIA driver + `/run/opengl-driver`** must exist on the host
  (`hardware.nvidia` / `hardware.graphics`); the module binds it read-only but
  doesn't configure the driver.
- The device whitelist assumes a standard `/dev/nvidia*` layout. Exotic setups
  (MIG, `nvidia-caps` beyond cap1/cap2) may need the list extended.
- The Python package set is opinionated (a broad data-science + LLM toolkit).
  Trim it to taste — it's a plain `withPackages` list in `default.nix`; add to it
  without editing the module via `extraPythonPackages`.
