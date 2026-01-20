{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.modules.services.ai-server;

  speachesTranscriptionModels = filter (m: m.backend == "speaches") cfg.transcriptionModels;
  speachesTtsModels = filter (m: m.backend == "speaches") cfg.ttsModels;
  hasSpeaches = speachesTranscriptionModels != [] || speachesTtsModels != [];

  primaryWhisperModel =
    if speachesTranscriptionModels != []
    then (head speachesTranscriptionModels).speaches.modelId
    else "Systran/faster-whisper-large-v3";
in {
  config = mkIf (cfg.enable && hasSpeaches) {
    systemd.services.speaches = {
      description = "Speaches AI speech processing service";
      after = ["network.target"];
      wantedBy = ["multi-user.target"];
      startLimitBurst = 2;
      startLimitIntervalSec = 60;

      environment = {
        UVICORN_HOST = "127.0.0.1";
        UVICORN_PORT = toString cfg.speachesPort;
        HF_HUB_CACHE = "${cfg.models}/hub";
        HF_HOME = "${cfg.models}";
        HF_HUB_OFFLINE = "1";
        HF_HUB_ENABLE_HF_TRANSFER = "0";
        DO_NOT_TRACK = "1";
        SPEACHES_WHISPER_MODEL = primaryWhisperModel;
        COMPUTE_TYPE = "float16";
        DEVICE = "cuda";
        LD_LIBRARY_PATH = "/run/opengl-driver/lib";
      };

      serviceConfig = {
        Type = "exec";
        ExecStart = "${cfg.speachesPackage}/bin/speaches";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStartSec = "300s";
        TimeoutStopSec = "30s";

        DynamicUser = true;
        StateDirectory = "speaches";
        StateDirectoryMode = "0750";
        CacheDirectory = "speaches";
        CacheDirectoryMode = "0750";
        ReadWritePaths = ["/tmp"];
        ReadOnlyPaths = [cfg.models "/nix/store"];

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = false; # GPU access
        MemoryDenyWriteExecute = false; # Python/PyTorch JIT
        DevicePolicy = "closed";
        DeviceAllow = [
          "/dev/null rw"
          "/dev/urandom r"
          "/dev/nvidiactl rw"
          "/dev/nvidia-modeset rw"
          "/dev/nvidia-uvm rw"
          "/dev/nvidia-uvm-tools rw"
          "/dev/nvidia0 rw"
          "/dev/nvidia-caps/nvidia-cap1 r"
          "/dev/nvidia-caps/nvidia-cap2 r"
        ];

        RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
        RestrictSUIDSGID = true;
        RemoveIPC = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictRealtime = true;
        CapabilityBoundingSet = ["CAP_SYS_NICE"];
        AmbientCapabilities = ["CAP_SYS_NICE"];
        SystemCallArchitectures = "native";
      };
    };
  };
}
