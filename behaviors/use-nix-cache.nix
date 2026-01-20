{
  config,
  lib,
  ...
}:
let
  cfg = config.behaviors.nix-cache;
in
{
  options.behaviors.nix-cache = {
    enable = lib.mkEnableOption "Use a local Nix binary cache";

    cacheUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://nix-cache.home.lan";
      description = "URL of the local Nix binary cache";
    };

    publicKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      ];
      description = "Public keys to trust for verifying cached packages";
    };

    fallbackToUpstream = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to fall back to cache.nixos.org if local cache misses";
    };

    priority = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "Priority of the local cache (lower = higher priority)";
    };
  };

  config = lib.mkIf cfg.enable {
    nix.settings = {
      substituters =
        [ "${cfg.cacheUrl}?priority=${toString cfg.priority}" ]
        ++ (lib.optional cfg.fallbackToUpstream "https://cache.nixos.org");

      trusted-public-keys = cfg.publicKeys;
    };
  };
}
