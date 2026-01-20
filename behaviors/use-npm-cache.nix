{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.behaviors.npm-cache;

  npmrcContent = ''
    registry=${cfg.cacheUrl}
    ${lib.optionalString cfg.strictSsl "strict-ssl=true"}
    ${lib.optionalString (!cfg.strictSsl) "strict-ssl=false"}
  '';

  npmrcFile = pkgs.writeText "npmrc" npmrcContent;
in
{
  options.behaviors.npm-cache = {
    enable = lib.mkEnableOption "Use a local npm registry cache";

    cacheUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://npm-cache.home.lan/";
      description = "URL of the npm registry cache";
    };

    strictSsl = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enforce strict SSL verification";
    };

    configureYarn = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to also configure Yarn to use the cache";
    };

    configurePnpm = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to also configure pnpm to use the cache";
    };
  };

  config = lib.mkIf cfg.enable {
    # System-wide npm configuration
    environment.etc."npmrc".source = npmrcFile;

    # Environment variables
    environment.variables = lib.mkMerge [
      {
        npm_config_registry = cfg.cacheUrl;
        NPM_CONFIG_REGISTRY = cfg.cacheUrl;
      }
      (lib.mkIf cfg.configureYarn {
        YARN_REGISTRY = cfg.cacheUrl;
        YARN_NPM_REGISTRY_SERVER = cfg.cacheUrl;
      })
      (lib.mkIf cfg.configurePnpm {
        PNPM_REGISTRY = cfg.cacheUrl;
      })
    ];

    # Yarn configuration for classic Yarn
    environment.etc."yarnrc" = lib.mkIf cfg.configureYarn {
      text = ''
        registry "${cfg.cacheUrl}"
        ${lib.optionalString (!cfg.strictSsl) "strict-ssl false"}
      '';
    };
  };
}
