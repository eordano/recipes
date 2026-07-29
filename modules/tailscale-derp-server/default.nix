# Self-hosted Tailscale DERP relay behind nginx.
#
# Wraps Tailscale's `derper` binary in a hardened systemd service, feeds it
# ACME-managed certificates via `-certmode=manual`, and (unless it runs
# directly on 443) fronts it with nginx so the relay is reachable on the
# standard HTTPS port. See README.md for the why and the traps.
#
# Usage:
#   imports = [ ./modules/tailscale-derp-server ];
#   services.derp-server = {
#     enable   = true;
#     hostname = "derp.example.com";  # must match the served TLS cert
#     # acmeHost = "example.com";     # optional: which ACME cert dir to read
#     # port     = 8443;              # derper's own listener (nginx proxies 443 -> this)
#     # stunPort = 3478;
#     # verifyClients = true;         # gate to your tailnet
#   };
#
# You must arrange the ACME certificate yourself, e.g.:
#   security.acme.certs."derp.example.com".group = "nginx";
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.derp-server;

  derper = pkgs.tailscale.derper;

  # Whether nginx fronts derper. When derper listens directly on 443 there is
  # no reverse proxy, so the nginx vhost + abuse filtering are irrelevant.
  useNginx = cfg.port != 443;

  # Directory under /var/lib/acme that holds fullchain.pem / key.pem.
  acmeDir = if cfg.acmeHost != null then cfg.acmeHost else cfg.hostname;
  acmeCertPath = "/var/lib/acme/${acmeDir}";

  # The group that owns the ACME material. Nothing here runs as root, so the
  # relay reads its certificate purely through group membership -- which means
  # this group has to be right, and is asserted below rather than assumed.
  acmeCert = config.security.acme.certs.${acmeDir} or null;
  certGroup =
    if cfg.acmeGroup != null then
      cfg.acmeGroup
    else if acmeCert != null then
      acmeCert.group
    else
      null;
in
{
  options.services.derp-server = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable DERP relay server";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      example = "derp.example.com";
      description = "Hostname for DERP server (must match the TLS certificate served to clients)";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8443;
      description = ''
        HTTPS port derper listens on. When set to anything other than 443,
        nginx is enabled and proxies public 443 traffic to this port. Set to
        443 to run derper directly with no reverse proxy.
      '';
    };

    stunPort = lib.mkOption {
      type = lib.types.port;
      default = 3478;
      description = "STUN port (opened on the firewall)";
    };

    verifyClients = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Pass `-verify-clients` to derper so it only relays for nodes in the
        local tailnet. Requires the Tailscale daemon to be running on this
        host. Prevents the relay from being abused as an open DERP.
      '';
    };

    acmeHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "example.com";
      description = ''
        Name of the ACME certificate directory under /var/lib/acme to read
        the cert from. Defaults to `hostname`. Use this when a single
        wildcard/SAN cert (issued for a different primary name) covers the
        DERP hostname.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "derper";
      description = "System user derper runs as. Must not be root.";
    };

    acmeGroup = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "nginx";
      description = ''
        Group owning the ACME certificate files, which the derper user joins in
        order to read them. Defaults to the `group` of the matching
        `security.acme.certs` entry, so normally you do not set this. Set it
        explicitly when the certificate is provisioned outside the NixOS ACME
        module and therefore cannot be discovered.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "derper";
      description = "Primary group for the derper user.";
    };

    fail2ban = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Register fail2ban jails that ban scanners hitting the relay: one on
          nginx 444 responses (probe requests to non-DERP paths) and one on
          derper "cert mismatch" TLS journal errors. Only active when nginx
          fronts derper (port != 443) and `services.fail2ban.enable` is true.
        '';
      };

      action = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "iptables-allports";
        description = ''
          fail2ban action for the DERP jails. `null` uses fail2ban's global
          default (`services.fail2ban.banaction`). Set to a named action if
          you want these jails to use a specific one.
        '';
      };

      bantime = lib.mkOption {
        type = lib.types.str;
        default = "168h";
        description = "Ban duration for the DERP jails.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall = {
      allowedUDPPorts = [
        config.services.tailscale.port
        cfg.stunPort
      ];
    };

    systemd.services.derp-server = {
      description = "DERP (Designated Encrypted Relay for Packets) server";
      after = [
        "network-online.target"
        "acme-finished-${acmeDir}.target"
      ] ++ lib.optional useNginx "nginx.service";
      wants = [
        "network-online.target"
        "acme-finished-${acmeDir}.target"
      ];
      wantedBy = [ "multi-user.target" ];

      path = [ pkgs.coreutils ];

      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = 5;

        # Runs as the service user, NOT root: `StateDirectory` already creates
        # /var/lib/derper owned by it, and the certificate is reached through
        # group membership. Polls first because the ACME files can lag the
        # acme-finished target, then symlinks them to the <hostname>.crt/.key
        # names derper expects.
        #
        # The readability test is the real thing rather than a root-side `su`
        # emulation of it, so a group misconfiguration fails the unit here with
        # a precise message instead of surfacing later as a TLS handshake error.
        ExecStartPre = pkgs.writeShellScript "derper-cert-links" ''
          set -euo pipefail

          i=0
          while [ $i -lt 30 ]; do
            if [ -r "${acmeCertPath}/fullchain.pem" ] && [ -r "${acmeCertPath}/key.pem" ]; then
              break
            fi
            i=$((i + 1))
            sleep 2
          done

          if [ ! -r "${acmeCertPath}/fullchain.pem" ] || [ ! -r "${acmeCertPath}/key.pem" ]; then
            echo "derp-server: cannot read ${acmeCertPath}/{fullchain,key}.pem as $(id -un):$(id -gn)." >&2
            echo "derp-server: that material is owned by group ${
              if certGroup != null then certGroup else "<unknown>"
            }; the ${cfg.user} user must be a member of it." >&2
            exit 1
          fi

          ln -sfn "${acmeCertPath}/fullchain.pem" "/var/lib/derper/${cfg.hostname}.crt"
          ln -sfn "${acmeCertPath}/key.pem" "/var/lib/derper/${cfg.hostname}.key"
        '';

        # -http-port=-1 disables plain HTTP; -certmode=manual reads the
        # symlinked ACME cert instead of derper's LetsEncrypt autocert.
        # When nginx fronts derper, bind the HTTPS listener to loopback only
        # (nginx proxies from 127.0.0.1) so the backend port can never be hit
        # directly even if the host firewall/cloud SG leaves it open. On the
        # direct-443 path bind all interfaces since there is no proxy.
        ExecStart = "${derper}/bin/derper -c=/var/lib/derper/derper.key -hostname=${cfg.hostname} -a=${if useNginx then "127.0.0.1" else ""}:${toString cfg.port} -http-port=-1 -stun-port=${toString cfg.stunPort} -certmode=manual -certdir=/var/lib/derper ${lib.optionalString cfg.verifyClients "-verify-clients"}";

        StateDirectory = "derper";
        StateDirectoryMode = "0700";

        User = cfg.user;
        Group = cfg.group;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        ReadOnlyPaths = [ "/var/lib/acme" ];
        ReadWritePaths = [ "/var/lib/derper" ];
        # Ambient cap lets the unprivileged user bind low STUN/relay ports.
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      };
    };

    assertions = [
      {
        assertion = cfg.user != "root";
        message = ''
          services.derp-server.user must not be root. The relay reads its
          certificate through membership of the group that owns it, so it never
          needs privilege.
        '';
      }
      {
        assertion = certGroup != null;
        message = ''
          services.derp-server cannot determine which group owns the ACME
          certificate in ${acmeCertPath}, so it cannot grant the ${cfg.user}
          user read access to it.

          Either define the certificate through the NixOS ACME module, e.g.
            security.acme.certs."${acmeDir}".group = "nginx";
          (its `group` is picked up automatically), or, if the certificate is
          provisioned some other way, name the owning group explicitly:
            services.derp-server.acmeGroup = "<group>";
        '';
      }
    ];

    users.groups.${cfg.group} = { };
    # Pin nginx gid so it is stable on hosts that don't otherwise define it.
    users.groups.nginx = lib.mkIf useNginx (lib.mkDefault { gid = 60; });
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      # Read access to the ACME material comes from joining whichever group owns
      # it -- derived from the cert definition rather than assumed to be nginx,
      # because that only happens to be true when a web server provisions it.
      extraGroups = lib.optional (certGroup != null) certGroup;
    };

    services.fail2ban.jails = lib.mkIf (cfg.fail2ban.enable && useNginx) {
      derp-bad-tls.settings = {
        enabled = true;
        filter = "derp-bad-tls";
        backend = "systemd";
        maxretry = 3;
        findtime = 600;
        bantime = cfg.fail2ban.bantime;
      } // lib.optionalAttrs (cfg.fail2ban.action != null) { action = cfg.fail2ban.action; };
      derp-probes.settings = {
        enabled = true;
        filter = "derp-probes";
        logpath = "/var/log/nginx/derp-probes.log";
        backend = "auto";
        maxretry = 3;
        findtime = 600;
        bantime = cfg.fail2ban.bantime;
      } // lib.optionalAttrs (cfg.fail2ban.action != null) { action = cfg.fail2ban.action; };
    };

    environment.etc = lib.mkIf (cfg.fail2ban.enable && useNginx) {
      "fail2ban/filter.d/derp-bad-tls.local".text = ''
        [Definition]
        failregex = ^.*http: TLS handshake error from <HOST>:[0-9]+: .*cert mismatch.*$
        journalmatch = _SYSTEMD_UNIT=derp-server.service
      '';
      "fail2ban/filter.d/derp-probes.local".text = ''
        [Definition]
        failregex = ^<HOST> - .* "(GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH|CONNECT) [^"]*" 444
      '';
    };

    services.nginx.enable = lib.mkDefault useNginx;
    services.nginx.virtualHosts.${cfg.hostname} = lib.mkIf useNginx (
      let
        upstream = "https://127.0.0.1:${toString cfg.port}";
        # Backend SSL verification off (derper serves a cert for `hostname` on
        # loopback); buffering off so relay streams don't stall.
        sharedProxyConfig = ''
          proxy_ssl_verify off;
          proxy_ssl_protocols TLSv1.2 TLSv1.3;
          proxy_ssl_server_name on;
          proxy_ssl_name ${cfg.hostname};
          proxy_ssl_session_reuse on;
          proxy_set_header Host ${cfg.hostname};
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_buffering off;
          proxy_request_buffering off;
        '';
        plainLocation = {
          proxyPass = upstream;
          recommendedProxySettings = false;
          extraConfig = sharedProxyConfig;
        };
        upgradeLocation = {
          proxyPass = upstream;
          proxyWebsockets = true;
          recommendedProxySettings = false;
          extraConfig = sharedProxyConfig + ''
            proxy_connect_timeout 10m;
            proxy_send_timeout 10m;
            proxy_read_timeout 10m;
          '';
        };
      in
      {
        forceSSL = true;
        useACMEHost = acmeDir;
        # HTTP/2 OFF: DERP uses HTTP/1.1 Upgrade semantics.
        http2 = false;
        extraConfig = ''
          server_tokens off;
          access_log /var/log/nginx/derp-access.log combined;
          error_log /var/log/nginx/derp-error.log warn;
        '';
        # Enumerate only real DERP endpoints; everything else returns 444
        # (connection closed, no response) so the box isn't a probe target.
        locations = {
          "= /derp" = upgradeLocation;
          "= /derp/probe" = plainLocation;
          "= /derp/latency-check" = plainLocation;
          "= /generate_204" = plainLocation;
          "= /robots.txt" = plainLocation;
          "= /bootstrap-dns" = plainLocation;
          "/" = {
            extraConfig = ''
              access_log /var/log/nginx/derp-probes.log combined;
              return 444;
            '';
          };
        };
      }
    );
  };
}
