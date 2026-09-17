{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.jupyterlabCuda;

  cpkgs = cfg.cudaPkgs;

  pythonEnv = cpkgs.python3.withPackages (
    ps:
    (with ps; [
      jupyter
      jupyterlab
      notebook
      ipykernel
      ipywidgets
      nbconvert
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
      jupyterlab-lsp
      python-lsp-server
      python-lsp-ruff
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
        enabled -- it is the only authentication in front of a tokenless
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
      inherit (cfg) group;
      isSystemUser = true;
      home = cfg.dataDir;
      createHome = true;
    };

    users.groups.${cfg.group} = {
      inherit (cfg) gid;
    };

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

      path =
        (with pkgs; [
          gcc
          glibc.dev
          cpkgs.python3Packages.pybind11
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

        LD_LIBRARY_PATH = "/run/opengl-driver/lib";
        CC = "${pkgs.gcc}/bin/gcc";
        CUDA_VISIBLE_DEVICES = cfg.cudaDevices;
        CUDA_HOME = "${cpkgs.cudaPackages.cudatoolkit}";
        NCCL_P2P_DISABLE = "1";

        CPLUS_INCLUDE_PATH = "${cpkgs.python3Packages.pybind11}/include";

        PYTORCH_CUDA_ALLOC_CONF = "expandable_segments:True";

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

        ExecStartPre = "${pkgs.deno}/bin/deno jupyter --install --force";

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

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;

        ReadWritePaths = [ cfg.dataDir ];
        BindReadOnlyPaths = [ "/run/opengl-driver" ];

        MemoryDenyWriteExecute = false;
        PrivateDevices = false;

        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];

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
        proxyWebsockets = true;
        recommendedProxySettings = true;
        extraConfig = ''
          proxy_set_header Accept-Encoding "";
          proxy_read_timeout 86400; # let a single cell run for a full day
        '';
      };
    };
  };
}
