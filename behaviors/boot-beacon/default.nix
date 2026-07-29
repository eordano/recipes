{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.behaviors.bootBeacon;
in
{
  options.behaviors.bootBeacon = {
    enable = lib.mkEnableOption "boot + tailscale-up console beacons";

    tailscaleTimeoutSec = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = ''
        Seconds to wait for tailscale to reach the Running state before
        giving up. The beacon exits *successfully* on timeout — it is
        informational and must never wedge multi-user.target.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Plain readiness beacon: fires as soon as the network is up. Answers
    # "what address do I SSH to?" on a machine you just rebooted blind.
    systemd.services.boot-beacon = {
      description = "Beacon: host has an IP and is ready for SSH";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # Prefer the default route's prefsrc: the source address the kernel
        # actually uses for outbound traffic, i.e. the correct "reach me here"
        # IP on a multi-homed box. Fall back to the first global IPv4, then
        # to "unknown" — never fail.
        ip=$(${pkgs.iproute2}/bin/ip -4 -j route show default \
          | ${pkgs.jq}/bin/jq -r 'first(.[] | select(.prefsrc)).prefsrc // empty')
        if [ -z "$ip" ]; then
          ip=$(${pkgs.iproute2}/bin/ip -4 -o addr show scope global \
            | ${pkgs.gawk}/bin/awk '{print $4}' | cut -d/ -f1 | head -1)
        fi
        echo "BEACON ready-for-ssh host=${config.networking.hostName} ip=''${ip:-unknown}"
      '';
    };

    # Tailnet beacon: only exists when tailscale is enabled. Answers
    # "did this box rejoin the tailnet?" after an unattended reboot/reinstall.
    # Resolved through config.services.tailscale.package so a pinned override
    # is honoured.
    systemd.services.tailscale-beacon = lib.mkIf config.services.tailscale.enable {
      description = "Beacon: host joined tailscale";
      wantedBy = [ "multi-user.target" ];
      after = [
        "tailscaled.service"
        "network-online.target"
      ];
      wants = [
        "tailscaled.service"
        "network-online.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        deadline=$(( $(date +%s) + ${toString cfg.tailscaleTimeoutSec} ))
        while [ "$(date +%s)" -lt "$deadline" ]; do
          state=$(${config.services.tailscale.package}/bin/tailscale status --json 2>/dev/null \
            | ${pkgs.jq}/bin/jq -r '.BackendState // "unknown"')
          if [ "$state" = "Running" ]; then
            ts_ip=$(${config.services.tailscale.package}/bin/tailscale ip -4 2>/dev/null | head -1)
            echo "BEACON tailscale-up host=${config.networking.hostName} ts_ip=''${ts_ip:-unknown}"
            exit 0
          fi
          sleep 5
        done
        # Exit 0 even on timeout: informational unit, must not block boot.
        echo "BEACON tailscale-timeout host=${config.networking.hostName} state=$state"
      '';
    };
  };
}
