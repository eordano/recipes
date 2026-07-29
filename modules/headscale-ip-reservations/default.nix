{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.services.headscale-ip-reservations;

  inherit (lib)
    mkIf
    mkOption
    mkEnableOption
    types
    ;

  reservationsFile = (pkgs.formats.json { }).generate "headscale-reservations.json" cfg.reservations;

  checkScript = pkgs.writeShellApplication {
    name = "headscale-ip-reservations-check";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail

      HEADSCALE=${lib.escapeShellArg cfg.headscaleCommand}
      RESERVATIONS=${reservationsFile}

      nodes=$("$HEADSCALE" nodes list -o json)

      # A node's given_name is what headscale hands back when a hostname is
      # already taken (myhost -> myhost-1), so reconcile on the hostname the machine
      # actually reports and treat every row sharing one as the same host.
      report=$(jq -n --argjson nodes "$nodes" --slurpfile want "$RESERVATIONS" '
        ($want[0] // {}) as $want
        | [ $nodes[]
            | { host: .name,
                given: .given_name,
                ips: [ .ip_addresses[]? | select(test("^100\\.")) ] } ] as $have
        | {
            # Only reserved hosts: phones and tablets report no hostname and all
            # arrive as "localhost", which is normal rather than drift.
            duplicates: (
              $have
              | map(select($want[.host] != null))
              | group_by(.host)
              | map(select(length > 1))
              | map({ host: .[0].host, rows: map(.given) })
            ),
            wrong_ip: [
              $have[]
              | . as $n
              | ($want[$n.host]) as $expected
              | select($expected != null)
              | select(($n.ips | index($expected)) == null)
              | { host: $n.host, given: $n.given, expected: $expected, actual: $n.ips }
            ],
            missing: [
              ($want | keys[])
              | . as $h
              | select(($have | map(.host) | index($h)) == null)
            ]
          }')

      dup=$(jq -r '.duplicates | length' <<<"$report")
      bad=$(jq -r '.wrong_ip   | length' <<<"$report")
      gone=$(jq -r '.missing   | length' <<<"$report")

      if [ "$dup" -eq 0 ] && [ "$bad" -eq 0 ]; then
        if [ "$gone" -eq 0 ]; then
          echo "headscale-reservations: OK — every reserved host holds its address"
        else
          echo "headscale-reservations: OK — every registered host holds its address ($gone reserved, not registered: $(jq -r '.missing | join(", ")' <<<"$report"))"
        fi
        exit 0
      fi

      # Loud and specific: a host that quietly re-registers under a new address
      # is invisible until someone goes looking, which is the whole failure this
      # guards against.
      if [ "$dup" -gt 0 ]; then
        echo "headscale-reservations: DUPLICATE registrations (host present more than once):" >&2
        jq -r '.duplicates[] | "  \(.host): rows \(.rows | join(", "))"' <<<"$report" >&2
      fi
      if [ "$bad" -gt 0 ]; then
        echo "headscale-reservations: WRONG address (does not match the reservation):" >&2
        jq -r '.wrong_ip[] | "  \(.host) (\(.given)): expected \(.expected), holds \(.actual | join(", "))"' <<<"$report" >&2
      fi
      if [ "$gone" -gt 0 ] && ${if cfg.reportMissing then "true" else "false"}; then
        echo "headscale-reservations: RESERVED but not registered:" >&2
        jq -r '.missing[] | "  \(.)"' <<<"$report" >&2
      fi

      if [ "$dup" -gt 0 ] || [ "$bad" -gt 0 ]; then
        exit 1
      fi
      exit 0
    '';
  };
in
{
  options.modules.services.headscale-ip-reservations = {
    enable = mkEnableOption "periodic check that headscale nodes hold their reserved addresses";

    reservations = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = lib.literalExpression ''
        {
          workstation = tailnetAddresses.workstation;
          buildhost = tailnetAddresses.buildhost;
        }
      '';
      description = ''
        Hostname to reserved tailnet address. Point this at whatever inventory
        already declares the fleet's addresses, so the check compares headscale
        against the same source of truth everything else uses.
      '';
    };

    headscaleCommand = mkOption {
      type = types.str;
      default =
        if config.services.headscale.enable or false then
          "${config.services.headscale.package}/bin/headscale"
        else
          "headscale";
      defaultText = "\${config.services.headscale.package}/bin/headscale";
      description = ''
        headscale binary used to enumerate nodes. Defaults to the configured
        package's absolute path, since the check runs with the restricted PATH
        that writeShellApplication builds from runtimeInputs and would not find
        it by name.
      '';
    };

    reportMissing = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Also report reserved hosts with no node at all. Off by default: a host
        that is merely powered off is not drift, and reporting it would train
        you to ignore this check.
      '';
    };

    interval = mkOption {
      type = types.str;
      default = "hourly";
      description = "systemd OnCalendar expression for the check.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.headscale-ip-reservations = {
      description = "Check headscale nodes against their reserved addresses";
      after = [ "headscale.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe checkScript;
        User = "root";
      };
    };

    systemd.timers.headscale-ip-reservations = {
      description = "Periodic headscale address reservation check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };

    environment.systemPackages = [ checkScript ];
  };
}
