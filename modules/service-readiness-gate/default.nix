{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.services.readiness-gates;

  inherit (lib)
    mkOption
    mkIf
    types
    mapAttrs'
    nameValuePair
    ;

  gateUnit = name: "${name}-ready.service";

  probeCommand =
    name: gate:
    let
      set = lib.filter (p: p != null) [
        (if gate.command != null then "command" else null)
        (if gate.tcp != null then "tcp" else null)
        (if gate.http != null then "http" else null)
      ];
    in
    if lib.length set != 1 then
      throw "readiness gate '${name}': set exactly one of command, tcp or http (got ${toString (lib.length set)})"
    else if gate.command != null then
      gate.command
    else if gate.tcp != null then
      "timeout 2 bash -c 'exec 3<>/dev/tcp/${gate.tcp.host}/${toString gate.tcp.port}'"
    else
      "curl -sf -o /dev/null --max-time 5 ${lib.escapeShellArg gate.http}";

  waitScript =
    name: gate:
    pkgs.writeShellApplication {
      name = "wait-for-${name}";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.bash
        pkgs.curl
      ]
      ++ gate.extraPackages;
      text = ''
        set -euo pipefail

        deadline=$(( SECONDS + ${toString gate.timeoutSeconds} ))
        until ${probeCommand name gate}; do
          if [ "$SECONDS" -ge "$deadline" ]; then
            echo "readiness gate '${name}': not ready after ${toString gate.timeoutSeconds}s" >&2
            exit 1
          fi
          sleep ${toString gate.intervalSeconds}
        done
        echo "readiness gate '${name}': ready"
      '';
    };

  gateOptions = types.submodule (
    { name, ... }:
    {
      options = {
        command = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "pg_isready -q";
          description = "Shell command that exits 0 once the dependency is ready.";
        };

        tcp = mkOption {
          type = types.nullOr (
            types.submodule {
              options = {
                host = mkOption {
                  type = types.str;
                  default = "127.0.0.1";
                };
                port = mkOption { type = types.port; };
              };
            }
          );
          default = null;
          description = "Wait until this TCP port accepts a connection.";
        };

        http = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "http://127.0.0.1:3903/health";
          description = "Wait until this URL answers with a success status.";
        };

        timeoutSeconds = mkOption {
          type = types.ints.positive;
          default = 120;
          description = ''
            Give up after this long. The gate then fails, which is the point:
            a dependent held back by a failed gate is far easier to diagnose
            than one restarting forever against something that never arrived.
          '';
        };

        intervalSeconds = mkOption {
          type = types.ints.positive;
          default = 1;
          description = "Seconds between probe attempts.";
        };

        after = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "postgresql.service" ];
          description = "Units the gate itself is ordered after.";
        };

        requires = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Units the gate pulls in and depends on.";
        };

        requiredBy = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "garage-init.service" ];
          description = ''
            Units that must not start until this gate has passed. Each gets
            `Requires=` and `After=` the gate, so a failed probe blocks them
            rather than letting them start against an unready dependency.
          '';
        };

        extraPackages = mkOption {
          type = types.listOf types.package;
          default = [ ];
          description = "Extra packages on the probe's PATH.";
        };

        wantedBy = mkOption {
          type = types.listOf types.str;
          default = [ "multi-user.target" ];
          description = "Targets that pull the gate in.";
        };
      };
    }
  );
in
{
  options.modules.services.readiness-gates = mkOption {
    type = types.attrsOf gateOptions;
    default = { };
    description = ''
      Readiness gates for units whose dependencies are ready some time after
      systemd considers them started.

      `After=` orders starts, not readiness: a Type=simple service counts as
      started the moment it forks, which is typically well before it accepts
      connections. Anything ordered only with `After=` therefore races it, and
      the usual symptom is a dependent that restarts forever, or worse, a setup
      step that silently does nothing and still reports success.

      A gate is a oneshot that polls until the dependency actually answers, so
      dependents can take a hard `Requires=` on something meaningful.
    '';
    example = lib.literalExpression ''
      {
        garage = {
          http = "http://127.0.0.1:3903/health";
          after = [ "garage.service" ];
          requiredBy = [ "garage-init.service" ];
        };
      }
    '';
  };

  config = mkIf (cfg != { }) {
    # mkMerge, not //: several gates may guard the same consumer, and their
    # Requires=/After= lists have to accumulate rather than overwrite.
    systemd.services = lib.mkMerge (
      [
        (mapAttrs' (
          name: gate:
          nameValuePair "${name}-ready" {
            description = "Wait until ${name} is ready";
            inherit (gate) after requires wantedBy;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = lib.getExe (waitScript name gate);
            };
          }
        ) cfg)
      ]
      ++ lib.flatten (
        lib.mapAttrsToList (
          name: gate:
          map (consumer: {
            ${lib.removeSuffix ".service" consumer} = {
              requires = [ (gateUnit name) ];
              after = [ (gateUnit name) ];
            };
          }) gate.requiredBy
        ) cfg
      )
    );
  };
}
