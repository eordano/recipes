{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.modules.services.ai-server;

  # LiteLLM package with langfuse/OTEL support
  litellmWithLangfuse = pkgs.python3Packages.toPythonApplication (
    pkgs.python3Packages.litellm.overridePythonAttrs (oldAttrs: {
      dependencies =
        (oldAttrs.dependencies or [])
        ++ pkgs.python3Packages.litellm.optional-dependencies.proxy
        ++ pkgs.python3Packages.litellm.optional-dependencies.extra_proxy
        ++ (with pkgs.python3Packages; [
          opentelemetry-api
          opentelemetry-sdk
          opentelemetry-exporter-otlp
        ]);
    })
  );

  # Convert model configs to LiteLLM model_list format
  mkLitellmChatModel = model: {
    model_name = model.name;
    litellm_params =
      if model.backend == "vllm" then {
        model = "hosted_vllm/${model.vllm.modelId}";
        api_base = "http://127.0.0.1:${toString model.vllm.port}/v1";
      } else {
        model = model.name;
        api_base = model.externalUrl;
        api_key = model.apiKey;
      };
  };

  mkLitellmEmbedModel = model: {
    model_name = model.name;
    litellm_params =
      if model.backend == "vllm" then {
        model = "hosted_vllm/${model.vllm.modelId}";
        api_base = "http://127.0.0.1:${toString model.vllm.port}/v1";
      } else {
        model = model.name;
        api_base = model.externalUrl;
        api_key = model.apiKey;
      };
    model_info = {mode = "embedding";};
  };

  mkLitellmTranscriptionModel = model: {
    model_name = model.name;
    litellm_params =
      if model.backend == "speaches" then {
        model = "openai/${model.speaches.modelId}";
        api_base = "http://127.0.0.1:${toString cfg.speachesPort}/v1";
        api_key = "dummy-key-for-local-service";
      } else {
        model = model.name;
        api_base = model.externalUrl;
        api_key = model.apiKey;
      };
    model_info = {mode = "audio_transcription";};
  };

  mkLitellmTtsModel = model: {
    model_name = model.name;
    litellm_params =
      if model.backend == "speaches" then {
        model = "openai/${model.speaches.modelId}";
        api_base = "http://127.0.0.1:${toString cfg.speachesPort}/v1";
        api_key = "dummy-key-for-local-service";
      } else {
        model = model.name;
        api_base = model.externalUrl;
        api_key = model.apiKey;
      };
    model_info = {mode = "audio_speech";};
  };
in {
  config = mkIf cfg.enable {
    services.litellm = {
      enable = true;
      host = "127.0.0.1";
      port = cfg.litellmPort;

      package = mkIf cfg.langfuse.enable litellmWithLangfuse;

      settings = {
        model_list =
          (map mkLitellmChatModel cfg.chatModels)
          ++ (map mkLitellmEmbedModel cfg.embeddingModels)
          ++ (map mkLitellmTranscriptionModel cfg.transcriptionModels)
          ++ (map mkLitellmTtsModel cfg.ttsModels)
          ++ (optional (cfg.ttsModels != []) {
            model_name = "tts";
            inherit (mkLitellmTtsModel (head cfg.ttsModels)) litellm_params;
            model_info = {mode = "audio_speech";};
          });

        litellm_settings = mkIf cfg.langfuse.enable {
          success_callback = ["otel"];
          failure_callback = ["otel"];
        };
      };

      environment = {
        LITELLM_DISABLE_USAGE_METRICS = "1";
        SCARF_NO_ANALYTICS = "True";
        DO_NOT_TRACK = "True";
        ANONYMIZED_TELEMETRY = "False";
        NO_DB = "True";
      } // optionalAttrs cfg.langfuse.enable {
        LANGFUSE_OTEL_HOST = cfg.langfuse.host;
      };
    };

    # Additional hardening on the litellm systemd unit
    systemd.services.litellm.serviceConfig = {
      PrivateNetwork = false;
      RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
      IPAddressDeny = mkIf (!cfg.langfuse.enable) "any";
      IPAddressAllow = mkIf (!cfg.langfuse.enable) ["127.0.0.0/8" "::1/128"];
      PrivateDevices = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
      RemoveIPC = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RestrictRealtime = true;
      SystemCallFilter = ["@system-service" "~@privileged"];
      SystemCallArchitectures = "native";
      EnvironmentFile = mkIf (cfg.langfuse.enable && cfg.langfuse.secretKeyFile != null) cfg.langfuse.secretKeyFile;
    };
  };
}
