{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.modules.services.ai-server;

  # Shared submodule for vLLM model options
  vllmModelOptions = {
    options = {
      modelId = mkOption {
        type = types.str;
        description = "HuggingFace model ID or path";
      };
      port = mkOption {
        type = types.port;
        description = "Port for vLLM service";
      };
      attentionBackend = mkOption {
        type = types.nullOr (types.enum ["FLASHINFER" "XFORMERS" "TORCH_SDPA"]);
        default = null;
        description = ''
          Attention backend for vLLM.
          - FLASHINFER: Default for decoder-only models (GPT, Llama, etc.)
          - XFORMERS: Alternative for decoder-only models
          - TORCH_SDPA: Required for encoder-only models (BERT, RoBERTa, e5-large, etc.)
        '';
      };
      vllmArgs = mkOption {
        type = types.attrsOf types.anything;
        default = {};
        description = "Additional vLLM key-value arguments (e.g. dtype, gpu-memory-utilization)";
      };
      vllmFlags = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Additional vLLM boolean flags (e.g. enforce-eager, enable-auto-tool-choice)";
      };
      cudaDevices = mkOption {
        type = types.str;
        default = "0";
        description = "CUDA device identifiers to use";
        example = "0 1";
      };
    };
  };

  # Chat/embedding model submodule (vllm or external backend)
  inferenceModelType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Model name identifier";
      };
      backend = mkOption {
        type = types.enum ["vllm" "external"];
        description = "Backend to use for this model";
      };
      vllm = mkOption {
        type = types.nullOr (types.submodule vllmModelOptions);
        default = null;
      };
      externalUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "URL for external API endpoint";
      };
      apiKey = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "API key for external providers";
      };
    };
  };

  # Speaches model submodule (speaches or external backend)
  speechModelType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Model name identifier";
      };
      backend = mkOption {
        type = types.enum ["speaches" "external"];
        description = "Backend to use for this model";
      };
      speaches = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            modelId = mkOption {
              type = types.str;
              description = "Model ID for Speaches";
            };
          };
        });
        default = null;
      };
      externalUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "URL for external API endpoint";
      };
      apiKey = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "API key for external providers";
      };
    };
  };

  # Computed lists
  vllmChatModels = filter (m: m.backend == "vllm") cfg.chatModels;
  vllmEmbeddingModels = filter (m: m.backend == "vllm") cfg.embeddingModels;
  allVllmModels = vllmChatModels ++ vllmEmbeddingModels;
  vllmServiceNames = map (model: "vllm-${model.name}.service") allVllmModels;

  speachesTranscriptionModels = filter (m: m.backend == "speaches") cfg.transcriptionModels;
  speachesTtsModels = filter (m: m.backend == "speaches") cfg.ttsModels;
  hasSpeaches = speachesTranscriptionModels != [] || speachesTtsModels != [];
in {
  imports = [
    ./vllm.nix
    ./speaches.nix
    ./litellm.nix
    ./nginx.nix
  ];

  options.modules.services.ai-server = {
    enable = mkEnableOption "AI inference server with vLLM, Speaches, and LiteLLM";

    # Nginx / domain configuration
    domain = mkOption {
      type = types.str;
      description = "Domain (virtualHost) for the main LiteLLM API";
    };

    enableSSL = mkOption {
      type = types.bool;
      default = false;
      description = "Enable SSL for nginx virtualHosts";
    };

    forceSSL = mkOption {
      type = types.bool;
      default = false;
      description = "Force SSL (redirect HTTP to HTTPS) for nginx virtualHosts";
    };

    useACMEHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "ACME host for SSL certificates (same as nginx useACMEHost)";
    };

    speachesDomain = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional separate domain for Speaches TTS/STT services";
    };

    vllmDomain = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional separate domain for direct vLLM access";
    };

    webRoot = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Optional static web root to serve at /";
    };

    # Model configuration
    chatModels = mkOption {
      type = types.listOf inferenceModelType;
      default = [];
      description = "List of chat/completion models";
    };

    embeddingModels = mkOption {
      type = types.listOf inferenceModelType;
      default = [];
      description = "List of embedding models";
    };

    transcriptionModels = mkOption {
      type = types.listOf speechModelType;
      default = [];
      description = "List of transcription (STT) models";
    };

    ttsModels = mkOption {
      type = types.listOf speechModelType;
      default = [];
      description = "List of text-to-speech models";
    };

    # Packages
    models = mkOption {
      type = types.package;
      description = "Package containing cached models (nix-hug buildCache output)";
    };

    speachesPackage = mkOption {
      type = types.package;
      description = "The speaches package to use";
    };

    # Ports
    litellmPort = mkOption {
      type = types.port;
      default = 5670;
      description = "Port for LiteLLM gateway";
    };

    speachesPort = mkOption {
      type = types.port;
      default = 1327;
      description = "Port for Speaches service";
    };

    # Langfuse observability
    langfuse = {
      enable = mkEnableOption "Langfuse LLM observability integration";

      host = mkOption {
        type = types.str;
        default = "https://cloud.langfuse.com";
        description = "Langfuse host URL";
      };

      secretKeyFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Path to environment file containing Langfuse API keys.
          The file should contain:
            LANGFUSE_PUBLIC_KEY=pk-lf-...
            LANGFUSE_SECRET_KEY=sk-lf-...
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.domain != "";
        message = "modules.services.ai-server: domain must be set";
      }
      {
        assertion = !cfg.forceSSL || cfg.useACMEHost != null;
        message = "modules.services.ai-server: useACMEHost must be set when forceSSL is enabled";
      }
      {
        assertion = allVllmModels != [] -> cfg.models != null;
        message = "modules.services.ai-server: models package must be set when vLLM models are configured";
      }
      {
        assertion = hasSpeaches -> cfg.speachesPackage != null;
        message = "modules.services.ai-server: speachesPackage must be set when speaches models are configured";
      }
    ];

    # Service ordering: litellm waits for backends
    systemd.services.litellm = {
      after =
        ["network-online.target"]
        ++ vllmServiceNames
        ++ optional hasSpeaches "speaches.service";
      wants =
        ["network-online.target"]
        ++ vllmServiceNames
        ++ optional hasSpeaches "speaches.service";
    };
  };
}
