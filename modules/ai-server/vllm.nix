{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.modules.services.ai-server;

  # Filter vLLM models from the lists
  vllmChatModels = filter (m: m.backend == "vllm") cfg.chatModels;
  vllmEmbeddingModels = filter (m: m.backend == "vllm") cfg.embeddingModels;
  allVllmModels = vllmChatModels ++ vllmEmbeddingModels;

  # Embedding service names (chat models wait for these)
  embeddingServiceNames = map (m: "vllm-${m.name}.service") vllmEmbeddingModels;

  # Create a vLLM systemd service for a model
  mkVllmService = model: let
    modelConfig = model.vllm;
    isChatModel = builtins.elem model vllmChatModels;
    args =
      [
        modelConfig.modelId
        "--host" "127.0.0.1"
        "--port" (toString modelConfig.port)
        "--tensor-parallel-size" "1"
      ]
      ++ (lib.flatten (
        lib.mapAttrsToList (key: value: [
          "--${key}"
          (toString value)
        ]) (modelConfig.vllmArgs or {})
      ))
      ++ (map (flag: "--${flag}") (modelConfig.vllmFlags or []));
  in
    nameValuePair "vllm-${model.name}" {
      description = "vLLM service for ${model.name}";
      # Chat models wait for embedding models to claim GPU memory first
      after = ["network.target"] ++ lib.optionals isChatModel embeddingServiceNames;
      wants = lib.optionals isChatModel embeddingServiceNames;
      wantedBy = ["multi-user.target"];
      startLimitBurst = 2;
      startLimitIntervalSec = 60;

      path = with pkgs; [
        gcc
        glibc.dev
        python3Packages.pybind11
        ninja
        cudaPackages.cudatoolkit
        cudaPackages.cuda_nvcc
      ];

      environment = {
        HOME = "/var/lib/vllm-${model.name}";
        CUDA_VISIBLE_DEVICES = modelConfig.cudaDevices;
        CUDA_HOME = "${pkgs.cudaPackages.cudatoolkit}";
        NCCL_P2P_DISABLE = "1";

        VLLM_LOGGING_LEVEL = "WARN";
        VLLM_TRACE_FUNCTION = "0";
        VLLM_USE_FLASHINFER_SAMPLER = "0";
        VLLM_DO_NOT_TRACK = "1";
        DO_NOT_TRACK = "1";
        VLLM_NO_USAGE_STATS = "1";
        HF_HUB_DISABLE_TELEMETRY = "1";
        OPENAI_API_KEY = "empty";

        XDG_CACHE_HOME = "%S/vllm-${model.name}/.cache";
        TRITON_CACHE_DIR = "/tmp/vllm-${model.name}-triton";
        TORCHINDUCTOR_CACHE_DIR = "%S/vllm-${model.name}/.cache/torchinductor";
        HF_HUB_CACHE = "${cfg.models}/hub";
        HF_HUB_OFFLINE = "1";
        LD_LIBRARY_PATH = "/run/opengl-driver/lib";
      }
      // lib.optionalAttrs (modelConfig.attentionBackend != null) {
        VLLM_ATTENTION_BACKEND = modelConfig.attentionBackend;
      };

      serviceConfig = {
        Type = "exec";
        ExecStart = "${pkgs.vllm}/bin/vllm serve ${escapeShellArgs args}";

        DynamicUser = true;
        Restart = "on-failure";
        RestartSec = "10s";
        TimeoutStartSec = "300s";
        TimeoutStopSec = "30s";

        StateDirectory = "vllm-${model.name}";
        StateDirectoryMode = "0750";
        CacheDirectory = "vllm-${model.name}";
        CacheDirectoryMode = "0750";
        RuntimeDirectory = "vllm-${model.name}";
        RuntimeDirectoryMode = "0750";

        ReadWritePaths = ["/tmp"];
        ReadOnlyPaths = ["/nix/store"];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;

        MemoryDenyWriteExecute = false; # CUDA/PyTorch JIT
        PrivateDevices = false; # GPU access
        RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK"];
        DevicePolicy = "closed";
        DeviceAllow = lib.flatten [
          "/dev/null rw"
          "/dev/urandom r"
          "/dev/tty rw"
          "/dev/nvidiactl rw"
          "/dev/nvidia-modeset rw"
          "/dev/nvidia-uvm rw"
          "/dev/nvidia-uvm-tools rw"
          (builtins.map (i: "/dev/nvidia${builtins.toString i} rw") (
            lib.splitString " " modelConfig.cudaDevices
          ))
          "/dev/nvidia-caps/nvidia-cap1 r"
          "/dev/nvidia-caps/nvidia-cap2 r"
        ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RemoveIPC = true;
        PrivateMounts = false; # JIT libraries
        PrivateUsers = false; # GPU access
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectClock = true;
        ProtectProc = "invisible";
        UMask = "0077";
        CapabilityBoundingSet = ["CAP_SYS_NICE"];
        AmbientCapabilities = ["CAP_SYS_NICE"];
      };
    };
in {
  config = mkIf (cfg.enable && allVllmModels != []) {
    systemd.services = listToAttrs (map mkVllmService allVllmModels);
  };
}
