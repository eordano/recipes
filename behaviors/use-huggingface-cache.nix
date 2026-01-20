{
  config,
  lib,
  ...
}: let
  cfg = config.behaviors.huggingface-cache;
in {
  options.behaviors.huggingface-cache = {
    enable = lib.mkEnableOption "Use a local Hugging Face cache";

    endpoint = lib.mkOption {
      type = lib.types.str;
      default = "https://hf-cache.home.lan";
      description = "URL of the Hugging Face cache proxy";
    };

    token = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "HuggingFace API token for accessing private/gated models";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.variables = {
      HF_ENDPOINT = cfg.endpoint;
      HUGGINGFACE_HUB_ENDPOINT = cfg.endpoint;
    } // lib.optionalAttrs (cfg.token != null) {
      HF_TOKEN = cfg.token;
    };
  };
}
