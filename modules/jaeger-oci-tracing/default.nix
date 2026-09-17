{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.modules.services.jaeger;
in
{
  options.modules.services.jaeger = {
    enable = mkEnableOption "Jaeger tracing service";

    domain = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "jaeger.example.com";
      description = "Domain name for the Jaeger UI (proxied via nginx with TLS).";
    };

    acmeHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "example.com";
      description = ''
        ACME host whose certificate the nginx vhost should reuse
        (services.nginx.virtualHosts.<domain>.useACMEHost). Set to null to
        manage the certificate elsewhere.
      '';
    };

    image = mkOption {
      type = types.str;
      default = "jaegertracing/all-in-one:latest";
      description = "OCI image reference for the Jaeger container.";
    };

    imageFile = mkOption {
      type = types.nullOr types.package;
      default = null;
      example = literalExpression "pkgs.dockerTools.pullImage { /* ... */ }";
      description = ''
        Optional pre-built image tarball to load instead of pulling `image`
        from a registry (e.g. a pinned `dockerTools.pullImage` result). When
        null, the container runtime pulls `image` by reference.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "jaeger";
      description = "System user that owns the data directory.";
    };

    group = mkOption {
      type = types.str;
      default = "jaeger";
      description = "Primary group for the Jaeger service user.";
    };

    uid = mkOption {
      type = types.int;
      default = 3300;
      description = "User ID for the Jaeger service user.";
    };

    gid = mkOption {
      type = types.int;
      default = 3300;
      description = "Group ID for the Jaeger service.";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/jaeger";
      description = "Directory to store Jaeger data.";
    };

    uiPort = mkOption {
      type = types.port;
      default = 16686;
      description = "Host port for the Jaeger UI (proxied through nginx).";
    };

    otlpGrpcPort = mkOption {
      type = types.port;
      default = 4317;
      description = ''
        Host port for OTLP gRPC ingest. Opened raw in the firewall and
        UNAUTHENTICATED -- restrict to a trusted network.
      '';
    };

    otlpHttpPort = mkOption {
      type = types.port;
      default = 4318;
      description = ''
        Host port for OTLP HTTP ingest. Opened raw in the firewall and
        UNAUTHENTICATED -- restrict to a trusted network.
      '';
    };

    network = mkOption {
      type = types.str;
      default = "jaeger";
      description = "Name of the docker network the container joins.";
    };

    otlpListenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "10.0.0.1";
      description = ''
        Host interface address the OTLP ingest ports (gRPC/HTTP) are published
        on. Docker publishes container ports with an iptables DNAT rule in the
        DOCKER chain that BYPASSES the NixOS `networking.firewall` INPUT chain,
        so a `0.0.0.0` bind is reachable on every interface regardless of
        `openFirewall`. Because OTLP ingest is UNAUTHENTICATED, this defaults to
        loopback. Set it to the address of a trusted interface (a VPN or private
        subnet address, e.g. "10.0.0.1") to let remote collectors reach the
        host. Only use "0.0.0.0" if a firewall in front of the box already
        restricts these ports to trusted collectors.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open the OTLP ingest ports in the `networking.firewall` INPUT chain.

        Note this is only a partial control: Docker's published-port DNAT rules
        live in the DOCKER iptables chain and bypass the NixOS firewall INPUT
        chain, so the effective exposure of the OTLP ports is governed by
        `otlpListenAddress`, not by this toggle. Opening the firewall is only
        meaningful for ports bound to a non-loopback address. OTLP ingest is
        UNAUTHENTICATED -- leave this off unless a trusted network already
        restricts access. The UI is never opened here; it is reached only via
        the nginx TLS vhost.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.domain != null;
        message = "modules.services.jaeger: domain must be set when enabled";
      }
    ];

    systemd.services.docker-jaeger = {
      after = [ "docker-network-jaeger.service" ];
      requires = [ "docker-network-jaeger.service" ];
    };

    users.users.${cfg.user} = {
      inherit (cfg) uid;
      isSystemUser = true;
      home = cfg.dataDir;
      inherit (cfg) group;
    };

    users.groups.${cfg.group}.gid = cfg.gid;

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 ${toString cfg.uid} ${toString cfg.gid} - -"
    ];

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [
      cfg.otlpGrpcPort
      cfg.otlpHttpPort
    ];

    systemd.services."docker-network-jaeger" = {
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      before = [ "docker-jaeger.service" ];
      wantedBy = [ "multi-user.target" ];
      script = ''
        ${pkgs.docker}/bin/docker network inspect ${cfg.network} > /dev/null 2>&1 \
          || ${pkgs.docker}/bin/docker network create ${cfg.network}
      '';
    };

    virtualisation.oci-containers = {
      backend = "docker";
      containers.jaeger = {
        inherit (cfg) image;
        imageFile = mkIf (cfg.imageFile != null) cfg.imageFile;
        ports = [
          "127.0.0.1:${toString cfg.uiPort}:16686"
          "${cfg.otlpListenAddress}:${toString cfg.otlpGrpcPort}:4317"
          "${cfg.otlpListenAddress}:${toString cfg.otlpHttpPort}:4318"
        ];
        extraOptions = [
          "--network=${cfg.network}"
        ];
        autoStart = true;
      };
    };

    services.nginx.virtualHosts.${cfg.domain} = {
      forceSSL = true;
      useACMEHost = cfg.acmeHost;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString cfg.uiPort}/";
        proxyWebsockets = true;
      };
    };
  };
}
