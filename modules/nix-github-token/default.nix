{
  lib,
  config,
  ...
}:
let
  cfg = config.services.nix-github-token;
in
{
  options.services.nix-github-token = {
    enable = lib.mkEnableOption "authenticated github.com access for Nix fetches via a PAT";

    tokenFile = lib.mkOption {
      type = lib.types.str;
      example = "/run/secrets/github-pat";
      description = ''
        Path to a file that will contain the raw GitHub personal access token
        at runtime. Managed by your secret system of choice (agenix, sops-nix,
        a systemd credential, etc). The file only needs to be readable by root
        at activation time. If the file is absent the module quietly does
        nothing, so builds fall back to unauthenticated (rate-limited) access.
      '';
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "github.com";
      example = "github.example.com";
      description = ''
        Host the token authenticates against. Use your GitHub Enterprise host
        here if you fetch from a self-hosted instance.
      '';
    };

    runtimeFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/nix-github-access-tokens";
      description = ''
        tmpfs path the `access-tokens` line is written to and `!include`d from.
        Kept out of the Nix store on purpose -- it holds a secret.
      '';
    };

    activationDeps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "agenix" ];
      description = ''
        Activation-script dependencies to order this script *after*. Set this to
        whatever activation step decrypts/places `tokenFile` (e.g. "agenix" for
        agenix, "setupSecrets" for sops-nix) so the token exists when we read it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    system.activationScripts.nix-github-access-tokens = {
      text = ''
        if [ -r ${lib.escapeShellArg cfg.tokenFile} ]; then
          umask 077
          printf 'access-tokens = ${cfg.host}=%s\n' \
            "$(cat ${lib.escapeShellArg cfg.tokenFile})" > ${lib.escapeShellArg cfg.runtimeFile}
          chmod 0440 ${lib.escapeShellArg cfg.runtimeFile}
        fi
      '';
      deps = cfg.activationDeps;
    };

    nix.extraOptions = ''
      !include ${cfg.runtimeFile}
    '';
  };
}
