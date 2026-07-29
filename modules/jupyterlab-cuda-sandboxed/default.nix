# jupyterlab-cuda-sandboxed
#
# Run a GPU/CUDA JupyterLab (or any PyTorch / Triton / torch.compile JIT
# workload) as a native systemd service under a strict sandbox.
#
# The two traps this module solves:
#   1. CUDA JIT (Triton, TorchInductor, hand-written extensions) needs to map
#      W+X memory pages, so MemoryDenyWriteExecute MUST be false. And the
#      framework needs raw /dev/nvidia* nodes, so PrivateDevices MUST be false.
#      Everything else stays locked down; GPU access is narrowed back with
#      DevicePolicy=closed + an explicit per-index NVIDIA device whitelist.
#   2. ProtectSystem=strict makes the whole filesystem read-only except
#      ReadWritePaths. Every ML framework cache (HuggingFace, XDG, Triton,
#      TorchInductor) is therefore redirected under the one writable dataDir,
#      or the first import/compile blows up trying to write outside it.
#
# The notebook itself has NO token and NO password. It binds loopback
# (127.0.0.1) so the raw port is unreachable off-box regardless of firewall
# state; the nginx TLS vhost is the sole authenticator and front door. Never
# proxy it onto an untrusted network. Enabling asserts a domain + ACME host.
#
# Usage:
#   imports = [ ./jupyterlab-cuda-sandboxed ];
#   services.jupyterlabCuda = {
#     enable   = true;
#     domain   = "notebooks.example.com";
#     acmeHost = "notebooks.example.com";
#     # For recent CUDA wheels, point this at an unstable nixpkgs instance:
#     # cudaPkgs = inputs.nixpkgs-unstable.legacyPackages.${pkgs.system};
#   };

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.jupyterlabCuda;

  # Which nixpkgs instance provides python / torch / cudatoolkit. Defaults to
  # the host pkgs, but you almost certainly want to point this at an unstable
  # channel so the ML wheels track recent CUDA builds — and so torch resolves
  # to the SAME store closure your other CUDA services use (one shared
  # PyTorch build instead of compiling it once per service).
  cpkgs = cfg.cudaPkgs;

  pythonEnv = cpkgs.python313.withPackages (
    ps:
    (with ps; [
      # notebook stack
      jupyter
      jupyterlab
      notebook
      ipykernel
      ipywidgets
      nbconvert
      # ML / data
      numpy
      pandas
      matplotlib
      seaborn
      plotly
      scipy
      scikit-learn
      statsmodels
      sympy
      torch
      torchvision
      transformers
      scikit-image
      xgboost
      shap
      optuna
      # utility / io
      requests
      beautifulsoup4
      lxml
      sqlalchemy
      psycopg2
      openpyxl
      h5py
      pillow
      bokeh
      altair
      holoviews
      pytest
      black
      tqdm
      click
      joblib
      dask
      # language-server support for jupyterlab-lsp (Python side)
      jupyterlab-lsp
      python-lsp-server
      python-lsp-ruff
      # misc web / graph
      flask
      fastapi
      uvicorn
      pydantic
      httpx
      poetry-core
      networkx
      nltk
    ])
    ++ (cfg.extraPythonPackages ps)
  );

  # --- NVIDIA device whitelist ------------------------------------------------
  # DevicePolicy=closed denies every device node; this hands back exactly the
  # NVIDIA control/UVM/modeset/caps nodes plus one /dev/nvidiaN per GPU index.
  # So gpuIndices = [ "0" ] exposes precisely GPU 0 and nothing else.
  mkNvidiaDeviceAllow =
    { gpuIndices }:
    [
      "/dev/null rw"
      "/dev/urandom r"
      "/dev/tty rw"

      "/dev/nvidiactl rw"
      "/dev/nvidia-modeset rw"
      "/dev/nvidia-uvm rw"
      "/dev/nvidia-uvm-tools rw"
    ]
    ++ map (i: "/dev/nvidia${i} rw") gpuIndices
    ++ [
      "/dev/nvidia-caps/nvidia-cap1 r"
      "/dev/nvidia-caps/nvidia-cap2 r"
    ];
in
{
  options.services.jupyterlabCuda = {
    enable = lib.mkEnableOption "GPU/CUDA JupyterLab development server";

    domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "notebooks.example.com";
      description = ''
        nginx virtual-host name that fronts the notebook. Required when
        enabled — it is the only authentication in front of a tokenless
        JupyterLab.
      '';
    };

    acmeHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "notebooks.example.com";
      description = "ACME certificate host name (passed to nginx useACMEHost).";
    };

    cudaPkgs = lib.mkOption {
      type = lib.types.raw;
      default = pkgs;
      defaultText = lib.literalExpression "pkgs";
      description = ''
        nixpkgs instance used to build the Python env, torch and cudatoolkit.
        Point it at an unstable channel for recent CUDA wheels, and share it
        with any other CUDA services so the PyTorch closure is built once.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "jupyter";
      description = "System user the service runs as.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "jupyter";
      description = "System group the service runs as.";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 3400;
      description = "Numeric uid for the service user.";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 3400;
      description = "Numeric gid for the service group.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8888;
      description = "Loopback port JupyterLab listens on behind nginx.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/jupyter";
      description = ''
        HOME, WorkingDirectory and the single writable path under
        ProtectSystem=strict. All framework caches live under it.
      '';
    };

    cudaDevices = lib.mkOption {
      type = lib.types.str;
      default = "0";
      example = "0 1";
      description = ''
        Space-separated GPU indices to expose. Drives both the systemd device
        whitelist and CUDA_VISIBLE_DEVICES.
      '';
    };

    bindIp = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address JupyterLab binds. Defaults to loopback so the tokenless port is
        unreachable off-box regardless of firewall state; nginx is the sole
        front door. Only widen this if you understand the exposure.
      '';
    };

    extraPythonPackages = lib.mkOption {
      type = lib.types.functionTo (lib.types.listOf lib.types.package);
      default = _ps: [ ];
      defaultText = lib.literalExpression "ps: [ ]";
      description = ''
        Extra packages appended to the notebook Python environment, as a
        function of the python package set (e.g. ps: [ ps.geopandas ]).
      '';
    };

    extraPath = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = ''
        Extra packages appended to the service PATH (e.g. additional
        jupyterlab-lsp language servers).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.domain != null;
        message = "services.jupyterlabCuda: domain must be set when enabled (it is the only front-door auth).";
      }
      {
        assertion = cfg.acmeHost != null;
        message = "services.jupyterlabCuda: acmeHost must be set when enabled.";
      }
    ];

    users.users.${cfg.user} = {
      inherit (cfg) uid;
      group = cfg.group;
      isSystemUser = true;
      home = cfg.dataDir;
      createHome = true;
    };

    users.groups.${cfg.group} = {
      inherit (cfg) gid;
    };

    # Pre-create the cache tree so the first import doesn't race against a
    # missing directory under the read-only root.
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 ${toString cfg.uid} ${toString cfg.gid} - -"
      "d ${cfg.dataDir}/notebooks 0755 ${toString cfg.uid} ${toString cfg.gid} - -"
      "d ${cfg.dataDir}/.cache 0755 ${toString cfg.uid} ${toString cfg.gid} - -"
      "d ${cfg.dataDir}/.cache/huggingface 0755 ${toString cfg.uid} ${toString cfg.gid} - -"
      "d ${cfg.dataDir}/.cache/transformers 0755 ${toString cfg.uid} ${toString cfg.gid} - -"
      "d ${cfg.dataDir}/.cache/hub 0755 ${toString cfg.uid} ${toString cfg.gid} - -"
      "d ${cfg.dataDir}/.cache/triton 0755 ${toString cfg.uid} ${toString cfg.gid} - -"
      "d ${cfg.dataDir}/.cache/torchinductor 0755 ${toString cfg.uid} ${toString cfg.gid} - -"
    ];

    systemd.services.jupyter = {
      description = "GPU/CUDA JupyterLab development server";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      # These reach the notebook runtime so torch.compile / Triton / hand-written
      # CUDA extensions can actually compile from inside a cell. jupyterlab-lsp
      # also shells out to these language servers for non-Python buffers.
      path =
        (with pkgs; [
          gcc
          glibc.dev
          cpkgs.python313Packages.pybind11
          ninja
          cpkgs.cudaPackages.cudatoolkit
          pyright
          gopls
          rust-analyzer
          clang-tools
          typescript-language-server
          nodejs
          deno
        ])
        ++ cfg.extraPath;

      environment = {
        HOME = cfg.dataDir;

        # Userspace NVIDIA driver, brought into the strict mount namespace by
        # BindReadOnlyPaths below.
        LD_LIBRARY_PATH = "/run/opengl-driver/lib";
        CC = "${pkgs.gcc}/bin/gcc";
        CUDA_VISIBLE_DEVICES = cfg.cudaDevices;
        CUDA_HOME = "${cpkgs.cudaPackages.cudatoolkit}";
        NCCL_P2P_DISABLE = "1";

        CPLUS_INCLUDE_PATH = "${cpkgs.python313Packages.pybind11}/include";

        PYTORCH_CUDA_ALLOC_CONF = "expandable_segments:True";

        # Every framework cache MUST live under dataDir (the sole writable path).
        HF_HOME = "${cfg.dataDir}/.cache/huggingface";
        TRANSFORMERS_CACHE = "${cfg.dataDir}/.cache/transformers";
        HF_HUB_CACHE = "${cfg.dataDir}/.cache/hub";

        XDG_CACHE_HOME = "${cfg.dataDir}/.cache";
        TRITON_CACHE_DIR = "${cfg.dataDir}/.cache/triton";
        TORCHINDUCTOR_CACHE_DIR = "${cfg.dataDir}/.cache/torchinductor";
      };

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        Restart = "always";
        RestartSec = 3;

        # Idempotent; --force keeps the Deno JS/TS kernel current across bumps.
        ExecStartPre = "${pkgs.deno}/bin/deno jupyter --install --force";

        # No token, no password: auth is entirely the nginx TLS vhost.
        ExecStart = ''
          ${pythonEnv}/bin/jupyter lab \
            --ip=${cfg.bindIp} \
            --port=${toString cfg.port} \
            --no-browser \
            --notebook-dir=${cfg.dataDir}/notebooks \
            --ServerApp.token="" \
            --ServerApp.password="" \
            --ServerApp.allow_origin="https://${cfg.domain}" \
            --ServerApp.trust_xheaders=True \
            --ServerApp.base_url="/" \
            --ServerApp.allow_remote_access=True
        '';

        # ---- sandbox --------------------------------------------------------
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;

        ReadWritePaths = [ cfg.dataDir ];
        BindReadOnlyPaths = [ "/run/opengl-driver" ];

        # THE TWO KNOBS CUDA FORCES OPEN:
        # JIT kernels need writable+executable pages.
        MemoryDenyWriteExecute = false;
        # torch needs raw /dev/nvidia* nodes.
        PrivateDevices = false;

        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];

        # ...but hand back only the NVIDIA nodes for the selected GPU indices.
        DevicePolicy = "closed";
        DeviceAllow = mkNvidiaDeviceAllow {
          gpuIndices = lib.splitString " " cfg.cudaDevices;
        };

        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RemoveIPC = true;
        PrivateMounts = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectClock = true;
        ProtectProc = "invisible";
        UMask = "0077";

        # Only capability kept: renice / thread-pin.
        CapabilityBoundingSet = [ "CAP_SYS_NICE" ];
        AmbientCapabilities = [ "CAP_SYS_NICE" ];

        SystemCallArchitectures = "native";
      };
    };

    services.nginx.virtualHosts.${cfg.domain} = {
      forceSSL = true;
      useACMEHost = cfg.acmeHost;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString cfg.port}/";
        proxyWebsockets = true; # kernel comm channel
        recommendedProxySettings = true;
        extraConfig = ''
          proxy_set_header Accept-Encoding "";
          proxy_read_timeout 86400; # let a single cell run for a full day
        '';
      };
    };
  };
}
