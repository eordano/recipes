# nut-ups-prometheus
#
# Wire a locally-attached UPS into NUT (Network UPS Tools) plus the Prometheus
# NUT exporter, everything bound to localhost. Two real-world traps are baked in
# as options:
#
#   1. Cheap / OEM "megatec"-style UPSes driven by `nutdrv_qx` are frequently
#      misidentified under `port = "auto"`, so they need an explicit
#      `vendorid`/`productid` USB match.
#   2. Auto-shutdown can be deliberately disabled (`MINSUPPLIES = 0` plus a
#      log-only `SHUTDOWNCMD`) so a critical-battery event rides the battery out
#      instead of powering the host down.
#
# Drop-in NixOS module. Import it and set at minimum `enable` and
# `passwordFile`.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.nut-ups-prometheus;
in
{
  options.services.nut-ups-prometheus = {
    enable = mkEnableOption "NUT-managed UPS + Prometheus exporter (localhost-only)";

    upsName = mkOption {
      type = types.str;
      default = "ups";
      description = "NUT UPS instance name. Used as `<name>@localhost` in upsc / dashboards.";
    };

    driver = mkOption {
      type = types.str;
      default = "usbhid-ups";
      description = ''
        NUT driver. `usbhid-ups` autodetects most APC Back-UPS / Smart-UPS USB
        models. Cheap / OEM "megatec"-protocol units typically need
        `nutdrv_qx` together with an explicit `vendorid`/`productid`.
      '';
    };

    port = mkOption {
      type = types.str;
      default = "auto";
      description = "NUT driver port (`auto` = USB autodetect).";
    };

    vendorid = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "0001";
      description = ''
        Optional USB vendor ID. Drivers such as `nutdrv_qx` often misidentify
        the device under `port = "auto"`, so pin the exact USB match here. Find
        it with `lsusb` (the `xxxx:yyyy` before the colon is the vendor ID).
      '';
    };

    productid = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "0000";
      description = "Optional USB product ID, paired with `vendorid`.";
    };

    description = mkOption {
      type = types.str;
      default = "Local UPS";
      description = "Human-readable description written to the UPS's `ups.conf` section.";
    };

    monUser = mkOption {
      type = types.str;
      default = "monuser";
      description = "NUT monitor user (the upsmon client that reads UPS state).";
    };

    passwordFile = mkOption {
      type = types.path;
      example = "/run/secrets/nut-ups-password";
      description = ''
        Path to a file containing the password for `monUser`. Provide it via
        whatever secrets mechanism you use (plain file, sops-nix, agenix, …).
        The file must be readable by the NUT daemons (mode 0440, owner/group
        matching the NUT service is a safe choice).
      '';
    };

    disableAutoShutdown = mkOption {
      type = types.bool;
      default = true;
      description = ''
        When true (the default), a critical-battery event does NOT power the
        host down: `MINSUPPLIES = 0` and `SHUTDOWNCMD` only logs. The machine
        rides the battery out. Set to false for the normal NUT behaviour of
        shutting the host down when the battery hits critical.
      '';
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Extra lines appended verbatim to this UPS's section in `ups.conf` —
        escape hatch for driver-specific settings not covered by the named
        options above.
      '';
    };

    exporterPort = mkOption {
      type = types.port;
      default = 9199;
      description = "prometheus-nut-exporter listen port (bound to 127.0.0.1).";
    };
  };

  config = mkIf cfg.enable {
    power.ups = {
      enable = true;
      mode = "standalone";

      ups.${cfg.upsName} = {
        inherit (cfg) driver port description;
        directives =
          lib.optional (cfg.vendorid != null) ''vendorid = "${cfg.vendorid}"''
          ++ lib.optional (cfg.productid != null) ''productid = "${cfg.productid}"''
          ++ lib.optional (cfg.extraConfig != "") cfg.extraConfig;
      };

      users.${cfg.monUser} = {
        upsmon = "primary";
        passwordFile = cfg.passwordFile;
      };

      upsmon = {
        monitor.${cfg.upsName} = {
          system = "${cfg.upsName}@localhost";
          user = cfg.monUser;
          passwordFile = cfg.passwordFile;
          type = "primary";
          powerValue = 0;
        };
        settings = mkIf cfg.disableAutoShutdown {
          # Ride the battery out: never trigger an automated shutdown.
          MINSUPPLIES = 0;
          SHUTDOWNCMD = ''"${pkgs.util-linux}/bin/logger -t upsmon ALERT: UPS reports critical battery; auto-shutdown intentionally disabled"'';
        };
      };
    };

    # Silence the "no discharge estimate" init warning some drivers emit.
    systemd.services.upsdrv.environment.NUT_QUIET_INIT_NDE_WARNING = "true";

    services.prometheus.exporters.nut = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = cfg.exporterPort;
      nutServer = "127.0.0.1";
      nutVariables = [
        "battery.charge"
        "battery.runtime"
        "battery.voltage"
        "battery.voltage.high"
        "battery.voltage.low"
        "battery.voltage.nominal"
        "input.voltage"
        "input.voltage.nominal"
        "input.frequency"
        "input.frequency.nominal"
        "output.voltage"
        "output.voltage.nominal"
        "output.current"
        "output.current.nominal"
        "output.frequency"
        "output.frequency.nominal"
        "output.powerfactor"
        "ups.load"
        "ups.power.nominal"
        "ups.temperature"
        "ups.status"
      ];
    };
  };
}
