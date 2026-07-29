# netflow-capture — declarative per-interface NetFlow/IPFIX capture with nfdump's nfpcapd.
#
# Turns `nfpcapd` (from the `nfdump` package) into a NixOS service that models an
# arbitrary set of named packet-capture listeners as a submodule option tree. Each
# listener becomes its own `nfpcapd-<name>` systemd unit with independent worker
# threads, socket-buffer size, flow-expiration windows, rotation window, and an
# optional raw-pcap sidecar. Storage directories are auto-created via tmpfiles.
#
# Import it and set `services.nfpcapd.enable = true;` plus at least one listener.
#
# The two traps that make this non-obvious are documented inline below:
#   1. The unit runs as User=root even though nfpcapd is handed -u/-g: root is
#      required to open the raw capture socket, then nfpcapd drops privilege to
#      the unprivileged user itself.
#   2. nfpcapd will NOT create missing output paths, so every listener's output
#      subdir must be pre-created by tmpfiles or the daemon exits immediately.
{
  lib,
  config,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkOption
    types
    mkIf
    mkEnableOption
    ;
  cfg = config.services.nfpcapd;

  interfaceOpts = _: {
    options = {
      enable = mkEnableOption "Enable this listener";
      workerThreads = mkOption {
        description = "Number of worker threads to spawn. Helps when compression is enabled at high levels. Should not be higher than the number of logical cores of the listening machine.";
        default = 2;
        type = types.int;
      };

      socketBufferMB = mkOption {
        description = "set socket buffer size in MB (default 20MB)";
        default = 20;
        type = types.int;
      };

      nodeCacheSize = mkOption {
        description = "set node cache size in bytes (default 524288)";
        default = 524288;
        type = types.int;
      };

      interface = mkOption {
        description = "Interface to listen to. Defaults to the name of the listener.";
        default = null;
        type = types.nullOr types.str;
      };

      subdirectory = mkOption {
        description = "Define a subdirectory structure for captured files. Defaults to the listener's name";
        example = ''
          nfpcapd.subdirectory = "wired";
        '';
        default = null;
        type = types.nullOr types.str;
      };

      capturePcapDirectory = mkOption {
        description = "If set, also record raw pcap files to this target directory.";
        example = ''
          nfpcapd.capturePcapDirectory = "/var/log/nfpcapd/pcap";
        '';
        default = null;
        type = types.nullOr types.str;
      };

      snaplen = mkOption {
        description = "set the snapshot length (default 1522)";
        default = 1522;
        type = types.int;
      };

      activeExpirationSeconds = mkOption {
        description = "Set the active flow expire time in seconds (default 300)";
        default = 300;
        type = types.int;
      };

      inactiveExpirationSeconds = mkOption {
        description = "Set the inactive flow expire time in seconds (default 60)";
        default = 60;
        type = types.int;
      };

      rotateTime = mkOption {
        description = "Time window (seconds, or an nfdump time expression) to rotate pcap/nfcapd files.";
        default = 300;
        type = types.either types.int types.str;
      };

      verboseMode = lib.mkEnableOption "Whether to output capture data to stdout. Only use for debugging.";
      additionalOptions = mkOption {
        description = "Additional command line options to be passed to this nfpcapd listener";
        default = "";
        example = ''
          nfpcapd.additionalOptions = "-o fat,payload -z=lzo " + (
            if shouldOnlyCaptureDNSUDPPackets then "'port 53 and proto udp'" else ""
          );
        '';
        type = types.str;
      };
    };
  };
in
{
  options = {
    services.nfpcapd = {
      enable = mkOption {
        description = "Enable the capture of NetFlow data with nfpcapd";
        default = false;
        example = ''
          services.nfpcapd = {
            enable = true;
            listeners = {
              "wlo1" = {
                enable = true;
                subdirectory = "wireless";
              };
            };
          };
        '';
        type = types.bool;
      };
      storageDir = mkOption {
        description = "Folder to save capture data to. One subdirectory per listener is created underneath it.";
        default = "/var/log/netflow";
        type = types.str;
      };
      user = mkOption {
        description = "User that owns the on-disk capture output. nfpcapd drops to this user after opening the raw socket.";
        default = "nfpcapd";
        type = types.str;
      };
      group = mkOption {
        description = "Group for the on-disk capture output.";
        default = "nfpcapd";
        type = types.str;
      };

      listeners = mkOption {
        description = "Configuration of interfaces to listen to. One nfpcapd-<name> systemd unit is created per attribute.";
        default = { };
        example = ''
          eth0 = {
            enable = true;
            subdirectory = "wired";
          };
          wlo1 = {
            enable = true;
          };
        '';
        type = with types; attrsOf (submodule interfaceOpts);
      };
      globalAdditionalOptions = mkOption {
        description = "Additional command line options to be passed to all nfpcapd listeners";
        default = "";
        example = ''
          nfpcapd.globalAdditionalOptions = "-z=lzo " + (
            if shouldOnlyCaptureDNSUDPPackets then "'port 53 and proto udp'" else ""
          );
        '';
        type = types.str;
      };
    };
  };
  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.length (builtins.attrNames cfg.listeners) > 0;
        message = "At least one network interface must be configured in services.nfpcapd.listeners.";
      }
    ];

    # nfpcapd refuses to create missing output directories, so pre-create the base
    # storage dir, every listener's per-interface subdir, and any raw-pcap sidecar dir.
    systemd.tmpfiles.rules = [
      "d ${cfg.storageDir} 0750 ${cfg.user} ${cfg.group}"
    ]
    ++ (
      with builtins;
      (filter (_: _ != null) (
        (attrValues (
          mapAttrs (
            _: interfaceCfg:
            if interfaceCfg.capturePcapDirectory != null then
              "d ${interfaceCfg.capturePcapDirectory} 0750 ${cfg.user} ${cfg.group}"
            else
              null
          ) cfg.listeners
        ))
        ++ (attrValues (
          mapAttrs (
            interfaceName: interfaceCfg:
            "d ${cfg.storageDir}/${
              if interfaceCfg.subdirectory != null then interfaceCfg.subdirectory else interfaceName
            } 0750 ${cfg.user} ${cfg.group}"
          ) cfg.listeners
        ))
      ))
    );
    users.users.${cfg.user} = {
      isSystemUser = true;
      inherit (cfg) group;
    };
    users.groups.${cfg.group} = { };

    systemd.services = builtins.listToAttrs (
      builtins.attrValues (
        builtins.mapAttrs (
          listener: interfaceCfg:
          let
            interface = if interfaceCfg.interface != null then interfaceCfg.interface else listener;
          in
          {
            name = "nfpcapd-${listener}";
            value = {
              inherit (interfaceCfg) enable;
              description = "IPFIX/NetFlow capture daemon (nfpcapd)";
              after = [ "network.target" ];
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                ExecStart = ''
                  ${pkgs.nfdump}/bin/nfpcapd \
                    -u ${cfg.user} \
                    -g ${cfg.group} \
                    -i ${interface} \
                    -b ${toString interfaceCfg.socketBufferMB}MB \
                    -B ${toString interfaceCfg.nodeCacheSize} \
                    -w ${cfg.storageDir}/${
                      if interfaceCfg.subdirectory != null then interfaceCfg.subdirectory else listener
                    } \
                    -W ${toString interfaceCfg.workerThreads} \
                    -s ${toString interfaceCfg.snaplen} \
                    -e ${toString interfaceCfg.activeExpirationSeconds},${toString interfaceCfg.inactiveExpirationSeconds} \
                    -t ${
                      if lib.isInt interfaceCfg.rotateTime then
                        (toString interfaceCfg.rotateTime)
                      else
                        interfaceCfg.rotateTime
                    } \
                    ${
                      if interfaceCfg.capturePcapDirectory != null then "-p " + interfaceCfg.capturePcapDirectory else ""
                    } ${
                      if interfaceCfg.verboseMode then "-E" else ""
                    } ${interfaceCfg.additionalOptions} ${cfg.globalAdditionalOptions}'';
                Type = "simple";
                # Root is required to open the raw capture socket; nfpcapd then
                # drops to -u/-g itself. Do NOT set User=${cfg.user} here or the
                # socket open fails with EPERM.
                User = "root";
                Group = "root";
                ProtectHome = true;
                PrivateTmp = true;
                ProtectKernelModules = true;
                ProtectKernelTunables = true;
                Restart = "on-failure";
                RestartPreventExitStatus = 0;
                RestartSec = 5;
              };
            };
          }
        ) cfg.listeners
      )
    );
  };
}
