# hydra-ci-server
#
# Self-host Hydra (the Nix-native CI/CD system) behind nginx with a
# declaratively-provisioned PostgreSQL backend. This module is written against
# *upstream* NixOS options only (services.hydra, services.postgresql,
# services.nginx), so it is a drop-in you can import anywhere.
#
# The value here is not the wiring — it is the five non-obvious traps it takes
# to make Hydra actually run behind a reverse proxy on a DB you provisioned
# yourself. Each is called out inline below. See README.md for the "why".
#
# Usage:
#   imports = [ ./hydra-ci-server ];
#   services.hydra-ci-server = {
#     enable = true;
#     domain = "hydra.example.com";
#   };

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

  # Hydra's three fixed system users (created by upstream services.hydra) plus
  # root (for out-of-band psql), all mapped to the single `dbName` DB role.
  # These OS user names are fixed by Hydra upstream — do not rename them.
  # The third column is the target PG role, so it tracks cfg.dbName.
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
      # 8 GiB. Raise for heavy builds (e.g. CUDA/ML closures) that otherwise
      # trip Hydra's "output limit exceeded".
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
      port = cfg.port;
      notificationSender = cfg.notificationSender;
      buildMachinesFiles = optional (cfg.buildMachinesFile != null) cfg.buildMachinesFile;
      useSubstitutes = true;

      # TRAP 5 (IFD): Hydra evaluates in its own environment; the nix.conf
      # setting alone does not reach the evaluator, so pass it explicitly.
      extraEnv = mkIf cfg.allowImportFromDerivation {
        NIX_CONFIG = "allow-import-from-derivation = true";
      };

      extraConfig = ''
        max_output_size = ${toString cfg.maxOutputSize}
      '';
    };

    # ---- Declarative PostgreSQL backend --------------------------------------
    # The DB and role are provisioned here, NOT by hydra-init. See TRAP 4.
    services.postgresql = {
      enable = lib.mkDefault true;

      ensureDatabases = [ cfg.dbName ];
      ensureUsers = [
        {
          name = cfg.dbName;
          ensureDBOwnership = true;
        }
      ];

      # TRAP 1 (ident map): Hydra runs as three separate system users
      # (hydra, hydra-queue-runner, hydra-www). Peer auth authenticates by the
      # OS user name, so without a map only a role literally named
      # "hydra-queue-runner" etc. could connect. This map lets all three — plus
      # root, for manual psql — connect as the single `${cfg.dbName}` role.
      # (identMap is a plain string that appends to pg_ident.conf upstream.)
      identMap = identMapLines;

      # Peer-auth rule that activates the map above for local connections as
      # the hydra role. Appended to pg_hba.conf ahead of the default catch-all.
      authentication = mkBefore ''
        local all ${cfg.dbName} peer map=${identMapName}
      '';
    };

    # TRAP 2 (pg_trgm): Hydra's job/build search relies on trigram indexes.
    # Without the pg_trgm extension the schema init fails and Hydra will not
    # start evaluations. Upstream has no per-database setup hook, so create the
    # extension in a oneshot ordered before hydra-init.
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

    # ---- nginx reverse proxy -------------------------------------------------
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

    # TRAP 4 (.db-created sentinel): hydra-init bootstraps its own database on
    # first run — creating the role and DB and running its schema. Since we
    # already provisioned both declaratively above, pre-touch the sentinel it
    # checks so it skips that bootstrap (which would otherwise try to CREATE a
    # role/DB that already exist, and fail). mkBefore keeps this ahead of the
    # upstream preStart body.
    systemd.services.hydra-init.preStart = mkBefore ''
      mkdir -p ${cfg.stateDir}
      touch ${cfg.stateDir}/.db-created
    '';
  };
}
