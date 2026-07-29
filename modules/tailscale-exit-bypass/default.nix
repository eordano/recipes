# tailscale-exit-bypass
#
# Selectively divert chosen egress (by CIDR, and optionally by dport) OFF a
# Tailscale exit node and back onto the host's own WAN, using an fwmark +
# policy-routing rule plus a small nftables ruleset.
#
# Why this is subtle (the three traps this module exists to solve):
#
#   1. `type route hook output` — a plain `output` mangle chain marks the
#      packet but does NOT force the kernel to re-run the route lookup. Sockets
#      that connect() early and cache their destination route (notably
#      QEMU/SLIRP and other UDP sockets) never see the new mark's route. The
#      `route` hook triggers a route re-lookup after the mark is set, so those
#      cached-dest sockets actually get diverted.
#
#   2. MASQUERADE on the marked flow — the same early-connect() sockets also
#      cache their SOURCE address, chosen while the route still pointed at the
#      tailscale interface (a tailnet/CGNAT src). After we flip egress to WAN,
#      packets would leave with a now-wrong tailnet src and replies get dropped
#      as bogons. MASQUERADE on the marked flow rewrites src to the outgoing
#      interface address.
#
#   3. ip rule priority — the diverting rule must sit BELOW tailscale's rule
#      window (~5210-5290) so it is consulted first. It targets the `main`
#      table, which still holds the real WAN default, because tailscale's exit
#      default route lives in a separate table (commonly 52), not in `main`.
#
# Failure mode is fail-OPEN: if the rules are absent, traffic falls back to the
# host default route (the tailscale exit). No IP leak, just the un-bypassed
# path. For fail-closed behaviour, add your own REJECT in a parallel nft table.
#
# This module is self-contained: import it, set `enable = true`, and declare
# one or more named `routes`.

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.tailscaleExitBypass;

  enabledRoutes = lib.filterAttrs (_: r: r.enable) cfg.routes;

  buildApplyScript =
    name: route:
    pkgs.writeShellScript "tailscale-exit-bypass-${name}-apply" ''
      set -euo pipefail
      umask 077
      PATH=${
        lib.makeBinPath [
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnused
          pkgs.iproute2
          pkgs.nftables
        ]
      }:$PATH

      state_dir=/run/tailscale-exit-bypass
      state_hash="$state_dir/${name}.hash"
      install -d -m 0700 "$state_dir"

      static_cidrs=${lib.escapeShellArg (lib.concatStringsSep "\n" route.cidrs)}
      raw="$static_cidrs"
      ${lib.optionalString (route.cidrSourceCommand != null) ''
        if extra=$(${route.cidrSourceCommand} 2>&1); then
          raw="$raw"$'\n'"$extra"
        else
          echo "tailscale-exit-bypass[${name}]: cidrSourceCommand failed: $extra" >&2
        fi
      ''}

      cidr_re='^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'
      cidrs=$(printf '%s\n' "$raw" | grep -E "$cidr_re" | sort -u || true)

      if [[ -z "$cidrs" ]]; then
        echo "tailscale-exit-bypass[${name}]: no valid CIDRs after validation, refusing to install" >&2
        exit 1
      fi

      new_hash=$(
        {
          printf '%s\n' "$cidrs"
          printf 'fwmark=%s\n' "${route.fwmark}"
          printf 'rule_priority=%s\n' "${toString route.rulePriority}"
          ${lib.optionalString (route.udpDport != null) ''
            printf 'udp_dport=%s\n' "${toString route.udpDport}"
          ''}
          ${lib.optionalString (route.tcpDport != null) ''
            printf 'tcp_dport=%s\n' "${toString route.tcpDport}"
          ''}
        } | sha256sum | awk '{print $1}'
      )
      old_hash=$(cat "$state_hash" 2>/dev/null || true)
      table_present=0
      nft list table inet tailscale-exit-bypass-${name} >/dev/null 2>&1 && table_present=1
      rule_present=0
      ip -4 rule show priority ${toString route.rulePriority} \
        | grep -q "fwmark ${route.fwmark}" && rule_present=1

      if [[ "$new_hash" == "$old_hash" \
            && "$table_present" == "1" \
            && "$rule_present" == "1" ]]; then
        exit 0
      fi

      set_elems=$(printf '%s\n' "$cidrs" | paste -sd, -)
      count=$(printf '%s\n' "$cidrs" | wc -l)

      nft -f - <<NFT
      add table inet tailscale-exit-bypass-${name}
      delete table inet tailscale-exit-bypass-${name}
      table inet tailscale-exit-bypass-${name} {
        set bypass_targets {
          type ipv4_addr
          flags interval
          elements = { $set_elems }
        }
        chain output_mark {
          type route hook output priority mangle; policy accept;
          ${
            if route.udpDport != null then
              "udp dport ${toString route.udpDport} ip daddr @bypass_targets meta mark set ${route.fwmark}"
            else if route.tcpDport != null then
              "tcp dport ${toString route.tcpDport} ip daddr @bypass_targets meta mark set ${route.fwmark}"
            else
              "ip daddr @bypass_targets meta mark set ${route.fwmark}"
          }
        }
        chain postrouting_snat {
          type nat hook postrouting priority srcnat; policy accept;
          meta mark ${route.fwmark} masquerade
        }
      }
      NFT

      while ip -4 rule del priority ${toString route.rulePriority} 2>/dev/null; do :; done
      ip -4 rule add fwmark ${route.fwmark} lookup main priority ${toString route.rulePriority}

      printf '%s\n' "$new_hash" > "$state_hash"
      printf '%s\n' "$cidrs" > "$state_dir/${name}.cidrs"
      echo "tailscale-exit-bypass[${name}]: installed $count CIDRs, mark ${route.fwmark} → main @ prio ${toString route.rulePriority}"
    '';

  buildTeardownScript =
    name: route:
    pkgs.writeShellScript "tailscale-exit-bypass-${name}-teardown" ''
      set -u
      PATH=${
        lib.makeBinPath [
          pkgs.nftables
          pkgs.iproute2
          pkgs.coreutils
        ]
      }:$PATH
      nft delete table inet tailscale-exit-bypass-${name} 2>/dev/null || true
      while ip -4 rule del priority ${toString route.rulePriority} 2>/dev/null; do :; done
      rm -f /run/tailscale-exit-bypass/${name}.hash \
            /run/tailscale-exit-bypass/${name}.cidrs \
            /run/tailscale-exit-bypass/${name}.probe.json 2>/dev/null || true
    '';

  buildProbeScript =
    name: route:
    pkgs.writeShellScript "tailscale-exit-bypass-${name}-probe" ''
      set -uo pipefail
      PATH=${
        lib.makeBinPath [
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnused
          pkgs.iproute2
          pkgs.jq
        ]
      }:$PATH

      state_dir=/run/tailscale-exit-bypass
      cidrs_file="$state_dir/${name}.cidrs"
      out_file="$state_dir/${name}.probe.json"
      now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

      write_status() {
        jq -n \
          --arg ts "$now" \
          --arg status "$1" \
          --arg msg "$2" \
          --arg sample "$3" \
          --arg dev "$4" \
          --arg fwmark "${route.fwmark}" \
          '{ ts: $ts, route: "${name}", status: $status, message: $msg,
             sample: $sample, dev: $dev, fwmark: $fwmark }' \
          > "$out_file"
      }

      if [[ ! -f "$cidrs_file" ]]; then
        write_status "unknown" "cidrs file missing — apply hasn't run" "" ""
        echo "tailscale-exit-bypass-probe[${name}]: cidrs file missing" >&2
        exit 1
      fi

      sample=$(head -n1 "$cidrs_file" | sed 's,/.*,,')
      if [[ -z "$sample" ]]; then
        write_status "unknown" "cidrs file empty" "" ""
        exit 1
      fi

      route_out=$(ip -4 route get "$sample" mark ${route.fwmark} 2>&1 || true)
      dev=$(printf '%s\n' "$route_out" | grep -oE 'dev [^ ]+' | head -n1 | awk '{print $2}')

      if [[ -z "$dev" ]]; then
        write_status "degraded" "ip route get returned no dev: $route_out" "$sample" ""
        echo "tailscale-exit-bypass-probe[${name}]: no dev in route output" >&2
        exit 1
      fi

      if [[ "$dev" =~ ^${route.probe.forbiddenDevPattern}$ ]]; then
        write_status "degraded" "egress dev '$dev' matches forbidden pattern" "$sample" "$dev"
        echo "tailscale-exit-bypass-probe[${name}]: DEGRADED — sample $sample → dev $dev (expected non-tailscale)" >&2
        exit 1
      fi

      write_status "ok" "egress dev '$dev'" "$sample" "$dev"
    '';

  routeOpts =
    { ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Per-route disable switch (the parent enable flag also gates everything).";
        };

        cidrs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [
            "203.0.113.10"
            "198.51.100.0/24"
          ];
          description = "Static IPv4 addresses or CIDRs to bypass off the exit node.";
        };

        cidrSourceCommand = lib.mkOption {
          type = lib.types.nullOr (lib.types.either lib.types.str lib.types.path);
          default = null;
          example = lib.literalExpression ''pkgs.writeShellScript "harvest" "grep -hoE '[0-9.]+' /etc/endpoints"'';
          description = ''
            Optional shell command, absolute path, or derivation that
            prints one IPv4 address or CIDR per line on stdout. Run at
            apply-time and re-run on every reassert. Output is unioned
            with `cidrs`, deduped, and re-validated against a strict IPv4
            regex before reaching the nft ruleset. Use this for
            destinations that rotate (e.g. parsed from a config file the
            application refreshes).
          '';
        };

        udpDport = lib.mkOption {
          type = lib.types.nullOr lib.types.port;
          default = null;
          description = "If set, only UDP traffic with this destination port matches the bypass.";
        };

        tcpDport = lib.mkOption {
          type = lib.types.nullOr lib.types.port;
          default = null;
          description = "If set, only TCP traffic with this destination port matches the bypass.";
        };

        fwmark = lib.mkOption {
          type = lib.types.str;
          example = "0x42";
          description = ''
            Hex fwmark stamped on matched packets and used by the ip
            rule. Must not collide with tailscale's 0x80000/0xff0000
            mask or other host modules' marks. A small value such as
            0x40-0x4f is a safe convention.
          '';
        };

        rulePriority = lib.mkOption {
          type = lib.types.int;
          example = 4500;
          description = ''
            ip rule priority (lower = checked first). Must be below
            tailscale's window (~5210-5290) for the bypass to take
            effect. A value in the 4500-4599 range is a safe convention.
          '';
        };

        probe = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Run a periodic probe asserting the bypass is in effect.";
          };
          intervalSeconds = lib.mkOption {
            type = lib.types.int;
            default = 300;
            description = "How often to run the probe.";
          };
          forbiddenDevPattern = lib.mkOption {
            type = lib.types.str;
            default = "tailscale[0-9]*";
            description = ''
              Regex (BRE) that the egress device MUST NOT match for the
              bypass to be considered healthy. The probe runs
              `ip route get <sample-cidr> mark <fwmark>` and inspects
              `dev <X>`; if `<X>` matches this pattern, the probe reports
              degraded status.
            '';
          };
        };
      };
    };
in
{
  options.services.tailscaleExitBypass = {
    enable = lib.mkEnableOption "host-side policy routing that diverts marked traffic off the default tailscale exit node and onto the main routing table";

    routes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule routeOpts);
      default = { };
      description = ''
        Named bypass routes. Each becomes its own nft table
        (`inet tailscale-exit-bypass-<name>`), oneshot service,
        reassert timer, and ip rule.
      '';
    };

    reassertSeconds = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = ''
        How often to re-run the apply script for each route. The script
        short-circuits when the resolved set + nft state + ip rule are
        all unchanged, so the steady-state cost is a few syscalls per
        tick. Reasserting survives `tailscale up` re-runs, transient
        config-fetch failures, and manual `ip rule` fiddling.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && enabledRoutes != { }) {
    assertions = lib.mapAttrsToList (name: route: {
      assertion = (route.cidrs != [ ]) || (route.cidrSourceCommand != null);
      message = "services.tailscaleExitBypass.routes.${name}: must set at least one of cidrs or cidrSourceCommand.";
    }) enabledRoutes;

    systemd.services =
      lib.mapAttrs' (
        name: route:
        lib.nameValuePair "tailscale-exit-bypass-${name}" {
          description = "Tailscale exit-node bypass route '${name}' (mark ${route.fwmark} → main @ prio ${toString route.rulePriority})";
          after = [
            "tailscaled.service"
            "network-online.target"
          ];
          wants = [
            "tailscaled.service"
            "network-online.target"
          ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = buildApplyScript name route;
            ExecReload = buildApplyScript name route;
            ExecStop = buildTeardownScript name route;
          };
        }
      ) enabledRoutes
      // lib.mapAttrs' (
        name: _:
        lib.nameValuePair "tailscale-exit-bypass-${name}-reassert" {
          description = "Re-assert tailscale-exit-bypass route '${name}' (timer-driven)";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.systemd}/bin/systemctl try-reload-or-restart tailscale-exit-bypass-${name}.service";
          };
        }
      ) enabledRoutes
      // lib.mapAttrs' (
        name: route:
        lib.nameValuePair "tailscale-exit-bypass-${name}-probe" {
          description = "Probe tailscale-exit-bypass route '${name}' (writes /run/tailscale-exit-bypass/${name}.probe.json)";
          after = [ "tailscale-exit-bypass-${name}.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = buildProbeScript name route;
          };
        }
      ) (lib.filterAttrs (_: r: r.probe.enable) enabledRoutes);

    systemd.timers =
      lib.mapAttrs' (
        name: _:
        lib.nameValuePair "tailscale-exit-bypass-${name}-reassert" {
          description = "Re-assert tailscale-exit-bypass route '${name}'";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2min";
            OnUnitActiveSec = "${toString cfg.reassertSeconds}s";
            Unit = "tailscale-exit-bypass-${name}-reassert.service";
          };
        }
      ) enabledRoutes
      // lib.mapAttrs' (
        name: route:
        lib.nameValuePair "tailscale-exit-bypass-${name}-probe" {
          description = "Probe tailscale-exit-bypass route '${name}'";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "5min";
            OnUnitActiveSec = "${toString route.probe.intervalSeconds}s";
            Unit = "tailscale-exit-bypass-${name}-probe.service";
          };
        }
      ) (lib.filterAttrs (_: r: r.probe.enable) enabledRoutes);
  };
}
