# Bootable portable Open AI inference image
#
# Build: nix build .#portable-open-ai-image
# Write: sudo dd if=result/iso/*.iso of=/dev/sdX bs=4M status=progress
#
# Provides an OpenAI-compatible API on port 80 (HTTP):
#   POST /v1/chat/completions  - Qwen3-8B (LLM)
#   POST /v1/embeddings        - E5-large (embeddings)
#   POST /v1/audio/transcriptions - Whisper large-v3 (ASR)
#   POST /v1/audio/speech      - Kokoro-82M (TTS)
{
  config,
  lib,
  pkgs,
  modulesPath,
  nix-hug-lib,
  speachesPackage,
  ...
}: let
  # Model definitions
  qwen3Model = nix-hug-lib.fetchModel {
    url = "Orion-zhen/Qwen3-8B-AWQ";
    rev = "main";
    repoInfoHash = "sha256-Z6cN2Lv0TSAYd/4lFiHynBJDvfqHPiHPMHdvlhgMIek=";
    fileTreeHash = "sha256-C/Cu3FE5+43vLse0qZqbvIwL31DcbbE6M8ocGA4qo/A=";
    derivationHash = "sha256-+3CwSHaQRX1lwy8jQVC9nsgl5k3taq4+xk8JK4xbvIY=";
  };

  e5Model = nix-hug-lib.fetchModel {
    url = "intfloat/multilingual-e5-large-instruct";
    rev = "main";
    repoInfoHash = "sha256-KS3HD18q6u/LIAA1tBY5jz0wsarBU85JpOn5M+YeZvE=";
    fileTreeHash = "sha256-cCAGFCDddzZdHYBdwTWTjHXZ6HJXtvVAT/BkNKnz4z0=";
    derivationHash = "sha256-mJDx5k1fJCGahM1GwO4qiq3eYSHU669BQUADOS3gyA8=";
  };

  whisperModel = nix-hug-lib.fetchModel {
    url = "Systran/faster-whisper-large-v3";
    rev = "main";
    repoInfoHash = "sha256-hRwVJ7i2iT5BQG6kEnGQqd5BzC18u75DQX54sBoin9s=";
    fileTreeHash = "sha256-c9h9wTwY4rwwzFPAUilsKrhn+o8YqGudZJ/ZwOKnHmg=";
    derivationHash = "sha256-xgzU3nBTPS+zotgKQyalWeNh1EmX7ZkFBaWcyZYemdw=";
  };

  kokoroModel = nix-hug-lib.fetchModel {
    url = "speaches-ai/Kokoro-82M-v1.0-ONNX";
    rev = "main";
    repoInfoHash = "sha256-+eumCsNLTigie1h/syJwzPnF2KR7BAgHvJnmBRQYa20=";
    fileTreeHash = "sha256-+Aea1c28vvS+pfOs2alshOajGzW6I7ujDVIIAQ5KlgI=";
    derivationHash = "sha256-v2BsX7lfzzytuLSTEpJccHHAyG09dzvTsF9pXYBSZOs=";
  };

  sileroVadModel = nix-hug-lib.fetchModel {
    url = "onnx-community/silero-vad";
    rev = "main";
    repoInfoHash = "sha256-vZRYToCFvMdtDMn6AgyHGfHHDUVhbwDTQAZMJufZeqE=";
    fileTreeHash = "sha256-f+/9fy13zID9i5mv7FwdwCs0oQskWJlJ7TK3VjOVI4A=";
    derivationHash = "sha256-oQJFaFW/LydVXv17Va7bAmvniXUwjZxMFpSVH1GUSF8=";
  };

  models = nix-hug-lib.buildCache {
    models = [qwen3Model e5Model whisperModel kokoroModel sileroVadModel];
    hash = "sha256-wuoKQ76K7VFSO4ExxbavKDc0I778OsL8Sywc4vbMpXI=";
  };
in {
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
    "${modulesPath}/installer/cd-dvd/channel.nix"
    ../modules/ai-server
  ];

  # Allow unfree packages (NVIDIA drivers, CUDA)
  nixpkgs.config = {
    allowUnfree = true;
    nvidia.acceptLicense = true;
    cudaSupport = true;
  };

  # ISO image settings
  isoImage = {
    isoName = "portable-open-ai.iso";
    edition = "ai-server";
    compressImage = false;
    makeEfiBootable = true;
    makeUsbBootable = true;
  };

  # AI server configuration
  modules.services.ai-server = {
    enable = true;
    domain = "localhost";
    webRoot = ./web;

    inherit models speachesPackage;

    chatModels = [
      {
        name = "qwen3-8b";
        backend = "vllm";
        vllm = {
          modelId = "Orion-zhen/Qwen3-8B-AWQ";
          port = 5663;
          vllmArgs = {
            dtype = "half";
            gpu-memory-utilization = 0.60;
            quantization = "awq";
            tool-call-parser = "hermes";
          };
          vllmFlags = [
            "enforce-eager"
            "enable-auto-tool-choice"
            "reasoning-parser=deepseek_r1"
          ];
        };
      }
    ];

    embeddingModels = [
      {
        name = "e5-large";
        backend = "vllm";
        vllm = {
          modelId = "intfloat/multilingual-e5-large-instruct";
          port = 5665;
          attentionBackend = "TORCH_SDPA";
          vllmArgs = {
            dtype = "half";
            gpu-memory-utilization = 0.05;
          };
          vllmFlags = ["enforce-eager"];
        };
      }
    ];

    transcriptionModels = [
      {
        name = "whisper";
        backend = "speaches";
        speaches.modelId = "Systran/faster-whisper-large-v3";
      }
    ];

    ttsModels = [
      {
        name = "kokoro";
        backend = "speaches";
        speaches.modelId = "speaches-ai/Kokoro-82M-v1.0-ONNX";
      }
    ];
  };

  # NVIDIA GPU support
  hardware.nvidia = {
    modesetting.enable = true;
    open = false;
    package = config.boot.kernelPackages.nvidiaPackages.production;
  };
  hardware.graphics.enable = true;
  services.xserver.videoDrivers = ["nvidia"];

  # Boot configuration
  boot = {
    loader.timeout = lib.mkForce 5;
    kernelModules = [
      "nvidia"
      "nvidia_modeset"
      "nvidia_uvm"
      "nvidia_drm"
      "nvme"
      "ahci"
      "xhci_pci"
      "usb_storage"
    ];
    kernelParams = ["nvidia-drm.modeset=1"];
  };

  # Networking
  networking = {
    hostName = "portable-open-ai";
    networkmanager.enable = true;
    wireless.enable = lib.mkForce false;
    useDHCP = lib.mkDefault true;
    firewall.enable = true;
    firewall.allowedTCPPorts = [80];
  };

  # Firmware support
  hardware.enableRedistributableFirmware = true;
  hardware.enableAllFirmware = true;

  # Nix settings
  nix.settings.experimental-features = ["nix-command" "flakes"];

  # Basic system packages
  environment.systemPackages = with pkgs; [
    htop
    nvtopPackages.nvidia
    curl
    jq
  ];

  # SSH access
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
    };
  };

  # Display status on console login
  services.getty.helpLine = ''

    Portable Open AI Inference Server
    ==================================
    API endpoint: http://<this-ip>:80/v1/
    Models: qwen3-8b, e5-large, whisper, kokoro

    Check service status:
      systemctl status vllm-qwen3-8b vllm-e5-large speaches litellm nginx

    Example usage:
      curl http://localhost/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d '{"model":"qwen3-8b","messages":[{"role":"user","content":"Hello"}]}'

  '';

  system.stateVersion = "24.11";
}
