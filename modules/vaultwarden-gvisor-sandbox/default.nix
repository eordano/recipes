{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.vaultwardenSandbox;

  runscHost = pkgs.writeShellScript "runsc-host" ''exec ${pkgs.gvisor}/bin/runsc --network=host "$@"'';

  vaultwardenImage = pkgs.dockerTools.buildLayeredImage {
    name = "vaultwarden";
    tag = "latest";
    contents = [
      cfg.package
      cfg.package.webvault
      pkgs.bash
      pkgs.coreutils
      pkgs.cacert
    ];
    config = {
      Cmd = [ "${cfg.package}/bin/vaultwarden" ];
      WorkingDir = "/data";
      Env = [
        "DATA_FOLDER=/data"
        "WEB_VAULT_FOLDER=${cfg.package.webvault}/share/vaultwarden/vault"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ];
    };
  };
in
{
  options.services.vaultwardenSandbox = {
    enable = mkEnableOption "gVisor-sandboxed Vaultwarden vault";

    package = mkOption {
      type = types.package;
      default = pkgs.vaultwarden;
      defaultText = literalExpression "pkgs.vaultwarden";
      example = literalExpression ''pkgs.vaultwarden.override { dbBackend = "postgresql"; }'';
      description = ''
        Vaultwarden build baked into the image. nixpkgs' default is the SQLite
        backend; a PostgreSQL DATABASE_URL needs a `dbBackend = "postgresql"`
        build, and `s3://` folders need the `s3` cargo feature.
      '';
    };

    backend = mkOption {
      type = types.enum [
        "podman"
        "docker"
      ];
      default = "podman";
      description = ''
        OCI backend the container runs on. `virtualisation.oci-containers.backend`
        is one setting per host, so a host whose other containers are docker
        picks "docker" here; the gVisor `runsc-host` runtime is registered with
        whichever daemon is chosen and the unit is named `<backend>-vaultwarden`.
      '';
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/vaultwarden";
      description = "Directory that holds the vault database and the env file.";
    };

    domain = mkOption {
      type = types.str;
      example = "vault.example.com";
      description = "Public domain served over HTTPS (also passed to Vaultwarden as DOMAIN).";
    };

    acmeHost = mkOption {
      type = types.str;
      example = "vault.example.com";
      description = ''
        Name of the security.acme certificate to use for this vhost
        (services.nginx.virtualHosts.<domain>.useACMEHost). You are expected to
        provision the cert separately via security.acme.certs.<acmeHost>.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 8222;
      description = "Loopback port the container binds and nginx proxies to.";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = ''
        Address the Vaultwarden container binds (ROCKET_ADDRESS). Because the
        container runs with `--network=host`, this is a host-wide bind, not a
        container-private one. It defaults to `127.0.0.1` so only the local
        nginx front-end (which terminates TLS) can reach the vault.

        Do NOT set this to `0.0.0.0` unless you fully understand the risk: the
        raw listener is plaintext HTTP, so binding all interfaces exposes the
        password vault API unencrypted on the LAN/tailnet/public network,
        bypassing the TLS layer entirely. Off-box access should go through
        nginx over HTTPS, not this port.
      '';
    };

    uid = mkOption {
      type = types.int;
      default = 8222;
      description = ''
        Numeric uid of the service user. A fixed uid is required because it
        owns dataDir on the host and is the uid the container runs as; pick any
        free system uid and keep it stable.
      '';
    };

    gid = mkOption {
      type = types.int;
      default = 8222;
      description = "Numeric gid of the service group (see uid).";
    };

    signupsAllowed = mkOption {
      type = types.bool;
      default = false;
      description = "Allow open registration of new accounts (SIGNUPS_ALLOWED).";
    };

    rsaKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/agenix/vaultwarden-rsa-key";
      description = ''
        Host path of a PEM RSA private key that signs the login JWTs, readable
        by `uid`. Mounted read-only and used instead of the key Vaultwarden
        generates under dataDir on first start. Instances that share a database
        must share this key, or a token issued by one is rejected by the other.
      '';
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        ATTACHMENTS_FOLDER = "s3://vault/attachments";
      };
      description = "Extra non-secret environment for the container; overrides the module's own keys.";
    };

    environmentFiles = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Extra KEY=value env files (secrets such as DATABASE_URL), read after
        `''${dataDir}/env`. Each must exist when the unit starts.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf (cfg.backend == "podman") {
      virtualisation.podman = {
        enable = true;
        extraPackages = [ pkgs.gvisor ];
      };

      virtualisation.containers.containersConf.settings.engine.runtimes.runsc-host = [
        "${runscHost}"
      ];
    })

    (mkIf (cfg.backend == "docker") {
      virtualisation.docker.daemon.settings.runtimes.runsc-host.path = "${runscHost}";
    })

    {
      services.nginx.enable = true;
      services.nginx.virtualHosts."${cfg.domain}" = {
        forceSSL = true;
        useACMEHost = cfg.acmeHost;

        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          proxyWebsockets = true;
        };
      };

      users = {
        users.vaultwarden = {
          inherit (cfg) uid;
          isSystemUser = true;
          group = "vaultwarden";
        };
        groups.vaultwarden.gid = cfg.gid;
      };

      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0700 ${toString cfg.uid} ${toString cfg.gid} - -"
      ];

      systemd.services."${cfg.backend}-vaultwarden".preStart = lib.mkAfter ''
        touch ${cfg.dataDir}/env
        chown -R ${toString cfg.uid}:${toString cfg.gid} ${cfg.dataDir}
      '';

      virtualisation.oci-containers.backend = cfg.backend;
      virtualisation.oci-containers.containers.vaultwarden = {
        imageFile = vaultwardenImage;
        image = "vaultwarden:latest";
        user = "${toString cfg.uid}:${toString cfg.gid}";
        environment = {
          DOMAIN = "https://${cfg.domain}";
          ROCKET_ADDRESS = cfg.listenAddress;
          ROCKET_PORT = toString cfg.port;
          ROCKET_LOG = "info";
          DATA_FOLDER = "/data";
          BACKUP_DIR = "/data/backup";
          SIGNUPS_ALLOWED = lib.boolToString cfg.signupsAllowed;
        }
        // optionalAttrs (cfg.rsaKeyFile != null) { RSA_KEY_FILENAME = "/run/vaultwarden-key/rsa_key"; }
        // cfg.environment;
        environmentFiles = [ "${cfg.dataDir}/env" ] ++ cfg.environmentFiles;
        extraOptions = [
          "--runtime=runsc-host"
          "--network=host"
        ];
        volumes = [
          "${cfg.dataDir}:/data"
        ]
        ++ optional (cfg.rsaKeyFile != null) "${cfg.rsaKeyFile}:/run/vaultwarden-key/rsa_key.pem:ro";
      };
    }
  ]);
}
