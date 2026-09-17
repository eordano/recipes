{ config, lib, ... }:

let
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    ;
  cfg = config.modules.nixCacheSubstituter;

  keyExists = cfg.keyFile != null && builtins.pathExists cfg.keyFile;
in
{
  options.modules.nixCacheSubstituter = {
    enable = mkEnableOption "a self-hosted binary cache as a substituter";

    domain = mkOption {
      type = types.str;
      example = "cache.example.com";
      description = ''
        Host of the binary cache. Used both as the substituter URL
        (`https://<domain>`) and, by default, to derive the key file name.
      '';
    };

    keyFile = mkOption {
      type = types.nullOr types.path;
      default = "/run/secrets/${cfg.domain}-key.pub";
      defaultText = lib.literalExpression ''"/run/secrets/''${domain}-key.pub"'';
      description = ''
        Path to the cache's public signing key file (a single
        `<name>:<base64>` line). Defaults to the `<domain>-key.pub`
        convention under a secrets directory; override when the key file
        name doesn't match the substituter domain, or point it wherever your
        secret-provisioning drops the file.

        If the file does not exist at evaluation time, the whole module is a
        no-op -- the host simply doesn't use this cache. Set to `null` to
        force-skip.
      '';
    };
  };

  config = mkIf (cfg.enable && keyExists) {
    nix.settings = {
      substituters = [ "https://${cfg.domain}" ];
      trusted-public-keys = [
        (lib.removeSuffix "\n" (builtins.readFile cfg.keyFile))
      ];
    };
  };
}
