{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.modules.jellyfin;
in
{
  options.modules.jellyfin = {
    enable = mkEnableOption "Jellyfin media server in an isolated container";

    dataDir = mkOption {
      type = types.str;
      default = "/srv/jellyfin/data";
      description = "Persistent state directory (bind-mounted to /data in the container).";
    };

    mediaDir = mkOption {
      type = types.str;
      default = "/srv/jellyfin/media";
      description = "Media library directory (bind-mounted read-write to /media in the container).";
    };

    domain = mkOption {
      type = types.str;
      example = "jellyfin.example.com";
      description = "FQDN for the nginx virtual host in front of the container.";
    };

    acmeHost = mkOption {
      type = types.str;
      example = "example.com";
      description = ''
        ACME host whose certificate nginx serves (services.nginx uses
        `useACMEHost`). Configure the certificate itself via `security.acme`
        elsewhere.
      '';
    };

    containerNetwork = {
      hostAddress = mkOption {
        type = types.str;
        default = "192.168.200.1";
        description = ''
          Host-side address of the veth pair. This is an arbitrary RFC1918
          default -- change it if it clashes with another subnet on the host.
        '';
      };

      localAddress = mkOption {
        type = types.str;
        default = "192.168.200.2";
        description = ''
          Container-side address of the veth pair (what nginx proxies to when
          `allowExternalConnections` is false).
        '';
      };
    };

    uid = mkOption {
      type = types.int;
      default = 3100;
      description = ''
        UID for the jellyfin system user. The value is arbitrary -- its only job
        is to be stable across rebuilds/hosts so the persisted `dataDir` stays
        chown-correct. Pick any free UID.

        On a host where a jellyfin account already exists under a different UID,
        set this to that UID: NixOS refuses to renumber an existing user (it
        only warns), so a mismatch leaves the declared and actual UID diverged.
      '';
    };

    gid = mkOption {
      type = types.int;
      default = 3100;
      description = "GID for the jellyfin system group (see `uid`).";
    };

    graphicsPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = ''
        Extra graphics packages installed inside the container. The container
        ships Intel VA-API drivers only; add your GPU's drivers here (e.g.
        AMD/Nvidia userspace) for other hardware.
      '';
    };

    nameservers = mkOption {
      type = types.listOf types.str;
      default = [ "1.1.1.1" ];
      description = "Resolvers used inside the container (host resolv.conf is not shared).";
    };

    allowExternalConnections = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Escape hatch. When true, drops `privateNetwork` so the container can
        reach the internet (e.g. plugin downloads), and nginx proxies to
        127.0.0.1 instead of the container's veth address. Leave false for the
        isolated-by-default posture.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.nginx = {
      enable = true;
      virtualHosts."${cfg.domain}" = {
        forceSSL = true;
        useACMEHost = cfg.acmeHost;

        locations."/" = {
          proxyPass = "http://${
            if cfg.allowExternalConnections then "127.0.0.1" else cfg.containerNetwork.localAddress
          }:8096";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_buffering off;
          '';
        };
      };
    };

    users = {
      users.jellyfin = {
        inherit (cfg) uid;
        group = "jellyfin";
        home = cfg.dataDir;
        isSystemUser = true;
      };
      groups.jellyfin.gid = cfg.gid;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 jellyfin jellyfin - -"
    ];

    containers.media = {
      autoStart = true;
      privateNetwork = lib.mkDefault (!cfg.allowExternalConnections);
      inherit (cfg.containerNetwork) hostAddress localAddress;
      extraFlags = [ "--link-journal=host" ];

      config = _: {
        system.stateVersion = "24.11";
        services.journald.settings.Journal = {
          Storage = "volatile";
          ForwardToSyslog = true;
        };

        services.jellyfin = {
          enable = true;
          openFirewall = !cfg.allowExternalConnections;
          dataDir = "/data";
        };

        hardware.graphics = {
          enable = true;
          enable32Bit = true;
          extraPackages =
            cfg.graphicsPackages
            ++ (with pkgs; [
              intel-media-driver
              intel-compute-runtime
              intel-vaapi-driver
              libvdpau-va-gl
            ]);
        };

        networking = {
          useHostResolvConf = lib.mkForce false;
          inherit (cfg) nameservers;
          firewall = {
            allowedTCPPorts = lib.optionals (!cfg.allowExternalConnections) [ 8096 ];
          };
        };

        environment.systemPackages = with pkgs; [
          jellyfin
          jellyfin-web
          jellyfin-ffmpeg
          yt-dlp
        ];

        users = {
          users.jellyfin = {
            inherit (cfg) uid;
            group = "jellyfin";
            extraGroups = [
              "render"
              "video"
            ];
            home = cfg.dataDir;
            isSystemUser = true;
          };
          groups.jellyfin.gid = cfg.gid;
          groups.render = { };
          groups.video = { };
        };
      };

      bindMounts = {
        "/media" = {
          hostPath = "${cfg.mediaDir}";
          isReadOnly = false;
        };
        "/data" = {
          hostPath = "${cfg.dataDir}";
          isReadOnly = false;
        };
        "/dev/dri" = {
          hostPath = "/dev/dri";
          isReadOnly = false;
        };
      };

      allowedDevices = [
        {
          modifier = "rw";
          node = "/dev/dri/renderD128";
        }
        {
          modifier = "rw";
          node = "/dev/dri/card0";
        }
      ];
    };
  };
}
