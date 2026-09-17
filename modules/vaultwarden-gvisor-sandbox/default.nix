{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.vaultwardenSandbox;

  vaultwardenImage = pkgs.dockerTools.buildLayeredImage {
    name = "vaultwarden";
    tag = "latest";
    contents = with pkgs; [
      vaultwarden
      vaultwarden.webvault
      bash
      coreutils
      cacert
    ];
    config = {
      Cmd = [ "${pkgs.vaultwarden}/bin/vaultwarden" ];
      WorkingDir = "/data";
      Env = [
        "DATA_FOLDER=/data"
        "WEB_VAULT_FOLDER=${pkgs.vaultwarden.webvault}/share/vaultwarden/vault"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ];
    };
  };
in
{
  options.services.vaultwardenSandbox = {
    enable = mkEnableOption "gVisor-sandboxed Vaultwarden vault";

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
  };

  config = mkIf cfg.enable (mkMerge [
    {
      virtualisation.podman = {
        enable = true;
        extraPackages = [ pkgs.gvisor ];
      };

      virtualisation.containers.containersConf.settings.engine.runtimes.runsc-host = [
        "${pkgs.writeShellScript "runsc-host" ''exec ${pkgs.gvisor}/bin/runsc --network=host "$@"''}"
      ];
    }

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

      systemd.services.podman-vaultwarden.preStart = lib.mkAfter ''
        touch ${cfg.dataDir}/env
        chown -R ${toString cfg.uid}:${toString cfg.gid} ${cfg.dataDir}
      '';

      virtualisation.oci-containers.backend = "podman";
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
        };
        environmentFiles = [ "${cfg.dataDir}/env" ];
        extraOptions = [
          "--runtime=runsc-host"
          "--network=host"
        ];
        volumes = [
          "${cfg.dataDir}:/data"
        ];
      };
    }
  ]);
}
