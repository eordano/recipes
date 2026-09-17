{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    mkPackageOption
    types
    ;
  cfg = config.services.headplane;

  headplaneConfigHardcodedPath = "/etc/headplane";
  headplaneStateHardcodedPath = "/var/lib/headplane";

  headscaleStablePath = "/var/lib/headscale";

  settingsFormat = pkgs.formats.yaml { };
  settingsFile = settingsFormat.generate "headplane-config.yaml" cfg.settings;
in
{
  disabledModules = [ "services/networking/headplane.nix" ];

  options.services.headplane = {
    enable = mkEnableOption "headplane (Headscale web UI)";
    package = mkPackageOption pkgs "headplane" { };

    user = mkOption {
      type = types.str;
      default = config.services.headscale.user or "headscale";
      defaultText = lib.literalExpression "config.services.headscale.user";
      description = ''
        User headplane runs as. Defaults to the headscale user so headplane can
        read headscale's state directory.
      '';
    };

    group = mkOption {
      type = types.str;
      default = config.services.headscale.group or "headscale";
      defaultText = lib.literalExpression "config.services.headscale.group";
      description = "Group headplane runs as. Defaults to the headscale group.";
    };

    settings = mkOption {
      type = types.submodule {
        freeformType = settingsFormat.type;
      };
      default = { };
      description = ''
        Headplane config; rendered to YAML. Do NOT put secrets here -- they would
        end up world-readable in /nix/store. Put secret file paths in
        `secretFiles` instead; they are spliced into the rendered config at boot.
        See https://github.com/tale/headplane/blob/main/config.example.yaml
      '';
    };

    secretFiles = {
      cookieSecret = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/agenix/headplane-cookie-secret";
        description = ''
          Path to a root-readable file containing headplane's session cookie
          secret. Spliced into `.server.cookie_secret` at boot. If null, the
          key is left as whatever `settings` provided.
        '';
      };

      oidcClientSecret = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/agenix/headplane-oidc-secret";
        description = ''
          Path to a root-readable file containing the OIDC client secret.
          Spliced into `.oidc.client_secret` at boot.
        '';
      };

      headscaleApiKey = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/agenix/headscale-api-key";
        description = ''
          Path to a root-readable file containing the Headscale API key.
          Spliced into `.headscale.api_key` at boot.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    systemd.services.headplane-sync-headscale-config = {
      description = "Copy headscale config to stable path for headplane";
      wantedBy = [ "headplane.service" ];
      before = [ "headplane.service" ];
      after = [ "headscale.service" ];
      partOf = [ "headscale.service" ];
      script = ''
        mkdir -p ${headscaleStablePath}
        cp -f ${config.services.headscale.configFile} ${headscaleStablePath}/config.yaml
        chown ${cfg.user}:${cfg.group} ${headscaleStablePath}/config.yaml
        chmod 640 ${headscaleStablePath}/config.yaml
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
      };
    };

    systemd.services.headplane-config-generator = {
      description = "Generate headplane configuration with secrets";
      wantedBy = [ "headplane.service" ];
      before = [ "headplane.service" ];
      after = [
        "headscale.service"
        "headplane-sync-headscale-config.service"
      ];
      partOf = [ "headscale.service" ];
      path = [ pkgs.yq-go ];

      script = ''
        # Create both dirs with tight modes *before* any secret is written, so
        # config.yaml is never reachable through a world-readable parent -- not
        # even in the window between the copy/splice and the final chmod.
        install -d -m 0700 -o ${cfg.user} -g ${cfg.group} ${headplaneStateHardcodedPath}
        install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${headplaneConfigHardcodedPath}
        rm -f ${headplaneConfigHardcodedPath}/config.yaml
        # Install the secret-free base config with an explicit owner-only-plus-group
        # mode up front; the splices below preserve it (yq edits in place).
        install -m 0640 -o ${cfg.user} -g ${cfg.group} ${settingsFile} ${headplaneConfigHardcodedPath}/config.yaml

        ${lib.optionalString (cfg.secretFiles.cookieSecret != null) ''
          COOKIE_SECRET=$(cat ${cfg.secretFiles.cookieSecret})
          export COOKIE_SECRET
          yq eval -i '.server.cookie_secret = strenv(COOKIE_SECRET)' ${headplaneConfigHardcodedPath}/config.yaml
        ''}
        ${lib.optionalString (cfg.secretFiles.oidcClientSecret != null) ''
          CLIENT_SECRET=$(cat ${cfg.secretFiles.oidcClientSecret})
          export CLIENT_SECRET
          yq eval -i '.oidc.client_secret = strenv(CLIENT_SECRET)' ${headplaneConfigHardcodedPath}/config.yaml
        ''}
        ${lib.optionalString (cfg.secretFiles.headscaleApiKey != null) ''
          API_KEY=$(cat ${cfg.secretFiles.headscaleApiKey})
          export API_KEY
          yq eval -i '.headscale.api_key = strenv(API_KEY)' ${headplaneConfigHardcodedPath}/config.yaml
        ''}

        touch ${headplaneStateHardcodedPath}/users.json

        # Re-assert ownership/modes in case yq's in-place rewrite reset them.
        chown -R ${cfg.user}:${cfg.group} ${headplaneStateHardcodedPath} ${headplaneConfigHardcodedPath}
        chmod 750 ${headplaneConfigHardcodedPath}
        chmod 640 ${headplaneConfigHardcodedPath}/config.yaml
        chmod 700 ${headplaneStateHardcodedPath}
        chmod 600 ${headplaneStateHardcodedPath}/users.json
      '';

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
      };
    };

    systemd.paths.headplane-watch-headscale-state = {
      description = "Watch headscale state for changes";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = [
          "${headscaleStablePath}/config.yaml"
          "${headscaleStablePath}/extra_records.json"
        ];
        Unit = "headplane-reload.service";
      };
    };

    systemd.services.headplane-reload = {
      description = "Reload headplane after headscale state change";
      script = ''
        /run/current-system/sw/bin/systemctl restart headplane.service
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
    };

    environment.systemPackages = [ cfg.package ];

    systemd.services.headplane = {
      description = "Headscale Web UI";

      wantedBy = [ "multi-user.target" ];
      after = [
        "headscale.service"
        "headplane-sync-headscale-config.service"
        "headplane-config-generator.service"
      ];
      wants = [ "headscale.service" ];

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;

        ExecStart = "${cfg.package}/bin/headplane";
        Restart = "always";
        RestartSec = 5;

        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;

        ReadWritePaths = [
          headplaneConfigHardcodedPath
          headplaneStateHardcodedPath
          headscaleStablePath
        ];
      };
    };
  };
}
