{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.hydra-ci-server;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    mkBefore
    types
    optional
    ;

  identMapName = "hydra";
  identMapLines = lib.concatStringsSep "\n" [
    "${identMapName} hydra               ${cfg.dbName}"
    "${identMapName} hydra-queue-runner  ${cfg.dbName}"
    "${identMapName} hydra-www           ${cfg.dbName}"
    "${identMapName} root                ${cfg.dbName}"
  ];
in
{
  options.services.hydra-ci-server = {
    enable = mkEnableOption "self-hosted Hydra CI/CD server behind nginx";

    domain = mkOption {
      type = types.str;
      example = "hydra.example.com";
      description = ''
        Public domain name for the Hydra web interface. Used both for the
        nginx virtual host and for the X-Request-Base header (see below) that
        Hydra uses to build absolute URLs.
      '';
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/hydra";
      description = "Directory to store Hydra state.";
    };

    port = mkOption {
      type = types.port;
      default = 3000;
      description = "Loopback port Hydra listens on (nginx proxies to it).";
    };

    dbName = mkOption {
      type = types.str;
      default = "hydra";
      description = ''
        PostgreSQL database and role name. Hydra's system users are peer-mapped
        onto this role; changing it also changes the ident map target.
      '';
    };

    notificationSender = mkOption {
      type = types.str;
      default = "hydra@${cfg.domain}";
      description = "From-address Hydra uses for failure notification emails.";
    };

    acmeHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "example.com";
      description = ''
        If set, the nginx vhost reuses this ACME certificate
        (services.nginx.virtualHosts.<domain>.useACMEHost). If null, nginx
        requests its own certificate for `domain` via enableACME. Either way
        the vhost is forced to SSL, because Hydra's absolute-URL scheme is
        https.
      '';
    };

    buildMachinesFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Optional path to a Nix build-machines file listing remote builders
        Hydra may dispatch jobs to. Null = build only on the local machine.
      '';
    };

    maxOutputSize = mkOption {
      type = types.int;
      default = 8 * 1024 * 1024 * 1024;
      description = "Max size (bytes) of a single build output before Hydra rejects it.";
    };

    allowImportFromDerivation = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable import-from-derivation (IFD) for evaluations that need it.
        Note: IFD evaluations cannot be gated by Hydra's `--no-build` pass, so
        jobsets that pull in IFD must be built rather than dry-evaluated.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.hydra = {
      enable = true;
      hydraURL = "https://${cfg.domain}";
      listenHost = "127.0.0.1";
      inherit (cfg) port;
      inherit (cfg) notificationSender;
      buildMachinesFiles = optional (cfg.buildMachinesFile != null) cfg.buildMachinesFile;
      useSubstitutes = true;

      extraEnv = mkIf cfg.allowImportFromDerivation {
        NIX_CONFIG = "allow-import-from-derivation = true";
      };

      extraConfig = ''
        max_output_size = ${toString cfg.maxOutputSize}
      '';
    };

    services.postgresql = {
      enable = lib.mkDefault true;

      ensureDatabases = [ cfg.dbName ];
      ensureUsers = [
        {
          name = cfg.dbName;
          ensureDBOwnership = true;
        }
      ];

      identMap = identMapLines;

      authentication = mkBefore ''
        local all ${cfg.dbName} peer map=${identMapName}
      '';
    };

    systemd.services.hydra-pg-trgm = {
      description = "Ensure pg_trgm extension exists in the Hydra database";
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      before = [ "hydra-init.service" ];
      requiredBy = [ "hydra-init.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        Group = "postgres";
      };
      script = ''
        ${config.services.postgresql.package}/bin/psql -d ${cfg.dbName} \
          -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm'
      '';
    };

    services.nginx = {
      enable = lib.mkDefault true;
      virtualHosts.${cfg.domain} = {
        forceSSL = true;
        useACMEHost = mkIf (cfg.acmeHost != null) cfg.acmeHost;
        enableACME = cfg.acmeHost == null;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_set_header X-Forwarded-Host   $host;
            proxy_set_header X-Forwarded-Server $host;
            proxy_set_header X-Forwarded-For    $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto  $scheme;
            # TRAP 3 (X-Request-Base): Hydra builds every absolute URL
            # (redirects, links, notification bodies) from THIS header, not
            # from Host. Omit it and links/redirects break behind the proxy.
            proxy_set_header X-Request-Base     "https://${cfg.domain}";
          '';
        };
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0755 hydra hydra -"
      "d /nix/var/nix/gcroots/hydra 0755 hydra hydra -"
    ];

    nix.settings = {
      trusted-users = [
        "hydra"
        "@hydra"
      ];
      allow-import-from-derivation = cfg.allowImportFromDerivation;
    };

    systemd.services.hydra-init.preStart = mkBefore ''
      mkdir -p ${cfg.stateDir}
      touch ${cfg.stateDir}/.db-created
    '';
  };
}
