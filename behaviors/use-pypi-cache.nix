{
  config,
  lib,
  ...
}:
let
  cfg = config.behaviors.pypi-cache;
in
{
  options.behaviors.pypi-cache = {
    enable = lib.mkEnableOption "Use PyPI cache proxy";

    cacheUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://pypi-cache.home.lan/index/";
      description = "URL of the PyPI cache proxy";
    };

    trustedHost = lib.mkOption {
      type = lib.types.str;
      default = "pypi-cache.home.lan";
      description = "Trusted host for the PyPI cache";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.cacheUrl != "";
        message = "behaviors.pypi-cache: cacheUrl must be set";
      }
      {
        assertion = cfg.trustedHost != "";
        message = "behaviors.pypi-cache: trustedHost must be set";
      }
    ];

    # Configure pip to use the cache for all users
    environment.etc."pip.conf".text = ''
      [global]
      index-url=${cfg.cacheUrl}
      [install]
      trusted-host=${cfg.trustedHost}
    '';
  };
}
