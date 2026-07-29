# Register a self-hosted binary cache as a substituter — but only once the
# host actually has the cache's public signing key.
#
# A Nix client with `require-sigs = true` (the default) will only accept
# NARs from a substituter if the matching public key is in its
# `trusted-public-keys`. So enabling a private cache means shipping two
# things to every client: the substituter URL *and* the public key file.
# The URL is static config; the key file usually arrives out-of-band (agenix
# / sops-nix / a provisioning step) and may not be present yet on a freshly
# bootstrapped or not-yet-provisioned host.
#
# The trap: if you unconditionally `readFile` the key, evaluation FAILS on
# any host that hasn't received the key file — you can't even build the
# system closure until the secret lands. That is exactly backwards: the
# cache is an optimization, its absence should never block evaluation.
#
# The fix: gate the whole config block behind `builtins.pathExists` on the
# key file. A host without the key silently skips the cache (building from
# source / other substituters) instead of failing to evaluate. Once the key
# is provisioned, the next evaluation picks it up automatically.
#
# Note: `pathExists` is evaluated at build time against the path as the
# evaluator sees it, so `keyFile` must be a real path readable during
# evaluation (a checked-in `.pub`, a decrypted secret already on disk, etc.),
# not a runtime-only path that appears after activation.
#
# Usage:
#   imports = [ ./private-nix-cache-substituter ];
#   modules.nixCacheSubstituter = {
#     enable  = true;
#     domain  = "cache.example.com";
#     keyFile = "/run/secrets/cache.example.com-key.pub";  # optional; see default
#   };
#
# The `.pub` file holds a single `<name>:<base64>` line as produced by
#   nix-store --generate-binary-cache-key cache.example.com-1 \
#     cache-priv-key.pem cache-pub-key.pem
# (publish and ship `cache-pub-key.pem`; keep the private half on the cache).

{ config, lib, ... }:

let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.modules.nixCacheSubstituter;

  # Evaluated at build time: true only when the key file is actually on disk
  # where the evaluator can read it. Guards the config block below so a host
  # missing the key skips the cache instead of aborting evaluation.
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
        no-op — the host simply doesn't use this cache. Set to `null` to
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
