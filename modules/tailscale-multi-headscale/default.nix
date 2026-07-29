# tailscale-multi-headscale
#
# Run one primary tailscaled plus any number of *extra* tailscaled instances,
# each joined to a SEPARATE Headscale server, on a single NixOS host — and
# survive the two non-obvious traps this creates (see README.md):
#
#   1. The primary daemon's `ts-input` chain drops CGNAT-range (100.64/10)
#      traffic that isn't "its own", which silently includes every extra
#      instance's peers. Fix: insert an early ACCEPT for each `ts-<name>`
#      interface ahead of that drop (`tailscale-firewall-fix-<name>`).
#
#   2. A Tailscale exit node installs a default route (table 52) via an ip-rule
#      at priority 5270 that hijacks local RFC1918 subnets — breaking Docker /
#      libvirt / LAN reachability. Fix: pin 172.16/12 and 192.168/16 back to the
#      `main` table with an ip-rule at priority 5269, just ahead of Tailscale's
#      (`local-network-tailscale-routing-fix`).
#
# This module carries NO secret-management wiring. Preauth keys are supplied as
# runtime file paths (`authKeyFile`), which you can populate with agenix,
# sops-nix, systemd credentials, or a plain root-only file — your choice.
#
# Drop-in: import this file as a NixOS module and set
# `modules.tailscale.enable = true`.
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.tailscale;

  logLevelType = lib.types.enum [
    "verbose"
    "debug"
    "info"
    "warn"
    "error"
  ];

  logLevelToVerbosity =
    level:
    if level == "verbose" then
      2
    else if level == "debug" then
      1
    else if level == "info" then
      0
    else if level == "warn" then
      -1
    else
      -2;

  allRoutes =
    (lib.optionals cfg.exitNode [
      "0.0.0.0/0"
      "::/0"
    ])
    ++ cfg.advertiseRoutes;
  routesFlag = lib.optionalString (
    allRoutes != [ ]
  ) "--advertise-routes=${lib.concatStringsSep "," allRoutes}";

  # Shared `tailscale up` bootstrap. Reads the preauth key from a file at
  # activation, only forces a re-auth when the daemon reports it is not
  # currently logged in, and (optionally) retries setting an exit node until it
  # appears in the netmap.
  mkInitScript =
    {
      scriptName,
      tailscaleCmd,
      authKeyPath,
      notConnectedMsg,
      loginServer,
      preAuthFlags ? [ ],
      extraFlags,
      useExitNode,
      readyTimeoutSeconds ? 30,
    }:
    let
      upFlags =
        preAuthFlags
        ++ [
          # `file:` makes tailscale read the key from the path itself, so the
          # secret never appears in this process's argv (/proc/<pid>/cmdline,
          # `ps`) during activation — only the file path does.
          "--authkey=file:${authKeyPath}"
          "\${FORCE_REAUTH:+$FORCE_REAUTH}"
        ]
        ++ extraFlags;
    in
    pkgs.writeShellScript scriptName ''
      set -euo pipefail

      # After= only orders unit starts, not readiness, so this can run while the
      # daemon is still coming up. Wait for it to actually answer before judging
      # the login state.
      BACKEND_STATE=""
      for _ in $(seq 1 ${toString readyTimeoutSeconds}); do
        CURRENT_STATUS=$(${tailscaleCmd} status --json 2>/dev/null || echo "")
        if [[ -n "$CURRENT_STATUS" ]]; then
          BACKEND_STATE=$(echo "$CURRENT_STATUS" | ${pkgs.jq}/bin/jq -r '.BackendState // ""')
          if [[ -n "$BACKEND_STATE" && "$BACKEND_STATE" != "NoState" ]]; then
            break
          fi
        fi
        sleep 1
      done

      # Re-authenticating with a preauth key mints a NEW node: on a fleet whose
      # keys are per-region, the host reappears under the region's user without
      # its tags, as a duplicate of itself, and the ACLs then refuse it. Only do
      # that when the daemon positively reports it needs a login. An unreachable
      # daemon tells us nothing, so leave the existing registration alone.
      FORCE_REAUTH=""
      if [[ -z "$BACKEND_STATE" ]]; then
        echo "tailscaled did not become responsive; leaving the existing registration untouched"
      elif [[ "$BACKEND_STATE" == "NeedsLogin" || "$BACKEND_STATE" == "NoState" ]]; then
        echo "${notConnectedMsg}"
        FORCE_REAUTH="--force-reauth"
      fi

      ${tailscaleCmd} up \
        --reset \
        --login-server=${loginServer} \
        --accept-dns=false \
        --host-routes=true \
        --snat-subnet-routes=true \
        --stateful-filtering=true \
        ${lib.concatStringsSep " \\\n  " upFlags}

      ${lib.optionalString (useExitNode != null) ''
        for i in $(seq 1 30); do
          if ${tailscaleCmd} set --exit-node=${useExitNode} 2>/dev/null; then
            echo "Exit node set to ${useExitNode}"
            break
          fi
          echo "Waiting for exit node ${useExitNode} to appear (attempt $i/30)..."
          sleep 2
        done
      ''}
    '';

in
{
  options.modules.tailscale = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the primary Tailscale/Headscale connection.";
    };

    authKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Runtime path to a file containing the primary instance's preauth key.
        Required when `enable = true`. Point this at whatever your secret
        manager decrypts to (agenix/sops-nix path, systemd credential, or a
        plain root-owned file).
      '';
      example = "/run/secrets/headscale-preauth-key";
    };

    loginServer = lib.mkOption {
      type = lib.types.str;
      default = "https://headscale.example.com";
      description = "Headscale login server URL for the primary instance.";
    };

    exitNode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Advertise this node as a Tailscale exit node.";
    };

    ssh = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable Tailscale SSH — tailscaled listens on the tailnet IP:22 and
        authenticates incoming connections by tailnet identity (governed by the
        Headscale ACL). Off by default; enable only where you trust tailnet
        identity as an auth path.
      '';
    };

    useExitNode = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Route this node's traffic through the named exit node.";
      example = "my-exit-node";
    };

    acceptRoutes = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Accept subnet routes advertised by other nodes.";
    };

    # The DERP relay is optional. It is only wired if `derperDomain` is set and
    # you have a `services.derp-server` module available (e.g. from a flake
    # input). Leave `derperDomain = null` and set `withoutDerp = true` to run an
    # exit node that does not participate in the DERP map.
    derperDomain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Public domain for a co-located DERP server (optional; requires an exit node).";
      example = "derp.example.com";
    };

    derperAcmeHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "ACME host whose certificate the DERP server should use. Defaults to `derperDomain` when null.";
      example = "example.com";
    };

    withoutDerp = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Run as an exit node without a co-located DERP server.";
    };

    advertiseRoutes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Subnet routes to advertise to the tailnet.";
      example = [
        "10.0.0.0/24"
        "fd00::/64"
      ];
    };

    logLevel = lib.mkOption {
      type = logLevelType;
      default = "warn";
      description = "Log verbosity for the primary tailscaled service.";
    };

    extraInstances = lib.mkOption {
      default = { };
      description = ''
        Additional tailscaled instances, each joined to its own Headscale
        server. Every instance gets a dedicated UDP port, TUN interface
        (`ts-<name>`), state directory and control socket. A `tailscale-<name>`
        wrapper is installed on PATH so you can run
        `tailscale-<name> status` against that instance's socket.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              loginServer = lib.mkOption {
                type = lib.types.str;
                description = "Headscale login server URL for this instance.";
                example = "https://other-headscale.example.com";
              };

              authKeyFile = lib.mkOption {
                type = lib.types.str;
                description = "Runtime path to a file containing this instance's preauth key.";
                example = "/run/secrets/other-headscale-preauth-key";
              };

              port = lib.mkOption {
                type = lib.types.port;
                default = 41642;
                description = "UDP port for this tailscaled instance (must not conflict with the primary or another instance).";
              };

              exitNode = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Advertise this instance as an exit node.";
              };

              useExitNode = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Route this instance through the named exit node.";
              };

              acceptRoutes = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Accept subnet routes advertised by other nodes on this instance's tailnet.";
              };

              logLevel = lib.mkOption {
                type = logLevelType;
                default = "warn";
                description = "Log verbosity for this tailscaled instance.";
              };

              hostname = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Override the hostname registered in Headscale for this instance.";
                example = "my-second-tailnet-node";
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkMerge [
    {
      assertions = lib.mkMerge [
        (lib.mkIf cfg.enable [
          {
            assertion = cfg.authKeyFile != null;
            message = "modules.tailscale.authKeyFile must be set when the module is enabled.";
          }
          {
            assertion = !cfg.exitNode || cfg.derperDomain != null || cfg.withoutDerp;
            message = "modules.tailscale.derperDomain must be set (or withoutDerp = true) when exitNode is true.";
          }
        ])

        (lib.mkMerge (
          map (
            name:
            let
              icfg = cfg.extraInstances.${name};
              interfaceName = "ts-${name}";
            in
            [
              {
                assertion = builtins.stringLength interfaceName <= 15;
                message = "modules.tailscale.extraInstances.${name}: interface name '${interfaceName}' exceeds 15 characters (Linux limit). Use a shorter instance name.";
              }
              {
                assertion = icfg.port != config.services.tailscale.port;
                message = "modules.tailscale.extraInstances.${name}: port ${toString icfg.port} conflicts with primary tailscale port ${toString config.services.tailscale.port}.";
              }
            ]
          ) (lib.attrNames cfg.extraInstances)
        ))
      ];

      networking.firewall = lib.mkMerge [
        (lib.mkIf cfg.enable {
          allowedUDPPorts = [ config.services.tailscale.port ];
          trustedInterfaces = [ "tailscale0" ];
        })
        (lib.mkIf (cfg.enable && cfg.exitNode) {
          allowedUDPPorts = [ 3478 ];
          allowedTCPPorts = [
            443
            80
          ];
        })

        (lib.mkMerge (
          map (
            name:
            let
              icfg = cfg.extraInstances.${name};
              interfaceName = "ts-${name}";
            in
            {
              allowedUDPPorts = [ icfg.port ];
              trustedInterfaces = [ interfaceName ];
            }
          ) (lib.attrNames cfg.extraInstances)
        ))
      ];

      # Only turn on IP forwarding where the host actually routes (exit node or
      # subnet router) — so enabling this module on a plain client doesn't quietly
      # make it a router.
      boot.kernel.sysctl =
        let
          anyForwarding =
            (cfg.enable && (cfg.exitNode || cfg.advertiseRoutes != [ ]))
            || lib.any (name: cfg.extraInstances.${name}.exitNode) (lib.attrNames cfg.extraInstances);
        in
        lib.mkIf anyForwarding {
          "net.ipv4.ip_forward" = lib.mkForce true;
          "net.ipv6.conf.all.forwarding" = lib.mkForce true;
        };

      # Per-instance CLI wrapper: `tailscale-<name> <args>` talks to that
      # instance's control socket.
      environment.systemPackages = lib.mkMerge [
        (map (
          name:
          let
            socketPath = "/run/tailscale-${name}/tailscaled.sock";
          in
          pkgs.writeShellScriptBin "tailscale-${name}" ''
            exec ${pkgs.tailscale}/bin/tailscale --socket=${socketPath} "$@"
          ''
        ) (lib.attrNames cfg.extraInstances))
      ];

      services.tailscale = lib.mkIf cfg.enable {
        enable = true;
        openFirewall = true;
        useRoutingFeatures = lib.mkDefault (
          if cfg.exitNode then
            "both"
          else if cfg.advertiseRoutes != [ ] then
            "server"
          else if cfg.useExitNode != null then
            "client"
          else
            "none"
        );
        extraDaemonFlags = [
          "-verbose=${toString (logLevelToVerbosity cfg.logLevel)}"
        ];
      };

      systemd.services = lib.mkMerge [
        # TRAP 2 — exit-node default route hijacks local RFC1918 subnets.
        # Pin 172.16/12 (Docker bridges) and 192.168/16 (LAN) back to the main
        # table at ip-rule priority 5269, just ahead of Tailscale's 5270.
        (lib.mkIf
          (
            cfg.enable
            && cfg.useExitNode != null
            && (config.virtualisation.docker.enable || config.virtualisation.libvirtd.enable)
          )
          {
            local-network-tailscale-routing-fix = {
              description = "Route local bridge/VM subnets via main table instead of Tailscale exit node";
              after = [
                "tailscale-init.service"
              ]
              ++ lib.optional config.virtualisation.docker.enable "docker.service"
              ++ lib.optional config.virtualisation.libvirtd.enable "libvirtd.service";
              wantedBy = [ "multi-user.target" ];

              path = [ pkgs.iproute2 ];

              script = ''
                ip rule add to 172.16.0.0/12 lookup main priority 5269 2>/dev/null || true
                ip rule add to 192.168.0.0/16 lookup main priority 5269 2>/dev/null || true
              '';

              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
            };
          }
        )

        (lib.mkIf cfg.enable {
          # A switch that stops tailscaled cuts the very tunnel it is being
          # delivered over, so the rest of the activation — including starting
          # the daemon again — never runs, and the host is simply gone until
          # someone reaches it another way. Restarting in place keeps the gap to
          # the daemon's own startup instead of spanning the whole switch.
          tailscaled.stopIfChanged = false;

          tailscale-init = {
            description = "Tailscale initialization service";
            after = [
              "network-online.target"
              "tailscaled.service"
            ];
            wants = [ "network-online.target" ];
            wantedBy = [ "multi-user.target" ];

            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = mkInitScript {
                scriptName = "tailscale-init";
                tailscaleCmd = "${pkgs.tailscale}/bin/tailscale";
                authKeyPath = cfg.authKeyFile;
                notConnectedMsg = "Not connected to Headscale server, forcing reauthentication...";
                loginServer = cfg.loginServer;
                extraFlags = [
                  (lib.optionalString cfg.ssh "--ssh")
                  (lib.optionalString cfg.acceptRoutes "--accept-routes")
                  (lib.optionalString cfg.exitNode "--advertise-exit-node")
                  routesFlag
                ];
                useExitNode = cfg.useExitNode;
              };
            };
          };
        })

        # TRAP 1 — the primary daemon's `ts-input` chain CGNAT-drops every extra
        # instance's peers. Insert an early ACCEPT for each `ts-<name>` interface
        # ahead of that drop. Probes both iptables and nftables backends and
        # no-ops if `ts-input` is absent (primary running --netfilter-mode=off).
        (lib.mkMerge (
          map (
            name:
            let
              interfaceName = "ts-${name}";
            in
            lib.mkIf cfg.enable {
              "tailscale-firewall-fix-${name}" = {
                description = "Accept ${interfaceName} traffic in INPUT before ts-input CGNAT drop";
                after = [
                  "tailscaled.service"
                  "tailscale-init.service"
                  "tailscaled-${name}.service"
                ];
                wants = [ "tailscaled-${name}.service" ];
                partOf = [ "tailscaled.service" ];
                wantedBy = [ "multi-user.target" ];

                path = [
                  pkgs.iptables
                  pkgs.nftables
                  pkgs.gawk
                ];

                script = ''
                  find_ts_input() {
                    if iptables -L ts-input -n &>/dev/null 2>&1; then
                      echo "iptables"
                      return
                    fi
                    nft list tables 2>/dev/null | while IFS= read -r line; do
                      family=$(echo "$line" | awk '{print $2}')
                      table=$(echo "$line" | awk '{print $3}')
                      if nft list chain "$family" "$table" ts-input &>/dev/null 2>&1; then
                        echo "nft:$family:$table"
                        return
                      fi
                    done
                  }

                  FW_MODE=""
                  for i in $(seq 1 15); do
                    FW_MODE=$(find_ts_input)
                    if [ -n "$FW_MODE" ]; then
                      break
                    fi
                    echo "Waiting for ts-input chain (attempt $i/15)..."
                    sleep 1
                  done

                  case "$FW_MODE" in
                    iptables)
                      iptables -C ts-input -i ${interfaceName} -j ACCEPT 2>/dev/null || \
                        iptables -I ts-input 1 -i ${interfaceName} -j ACCEPT
                      echo "Inserted iptables ACCEPT rule for ${interfaceName}"
                      ;;
                    nft:*)
                      NFT_FAMILY=$(echo "$FW_MODE" | cut -d: -f2)
                      NFT_TABLE=$(echo "$FW_MODE" | cut -d: -f3)
                      if ! nft list chain "$NFT_FAMILY" "$NFT_TABLE" ts-input 2>/dev/null | grep -q 'iifname "${interfaceName}"'; then
                        nft insert rule "$NFT_FAMILY" "$NFT_TABLE" ts-input iifname "${interfaceName}" accept
                      fi
                      echo "Inserted nftables ACCEPT rule for ${interfaceName} in $NFT_FAMILY $NFT_TABLE"
                      ;;
                    *)
                      echo "ts-input chain not found — primary tailscale likely running with --netfilter-mode=off, no CGNAT drop rule to work around"
                      exit 0
                      ;;
                  esac
                '';

                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
              };
            }
          ) (lib.attrNames cfg.extraInstances)
        ))

        # Per extra instance: its own tailscaled + its own init bootstrap.
        # Extra instances run --netfilter-mode=off so they never fight the
        # primary daemon's netfilter rules (the firewall-fix above re-opens the
        # one ACCEPT they actually need).
        (lib.mkMerge (
          map (
            name:
            let
              icfg = cfg.extraInstances.${name};
              interfaceName = "ts-${name}";
              statePath = "/var/lib/tailscale-${name}";
              socketPath = "/run/tailscale-${name}/tailscaled.sock";
            in
            {
              "tailscaled-${name}" = {
                description = "Tailscale daemon for ${name} instance";
                after = [ "network-online.target" ];
                wants = [ "network-online.target" ];
                wantedBy = [ "multi-user.target" ];

                serviceConfig = {
                  Type = "notify";
                  ExecStart = lib.concatStringsSep " " [
                    "${pkgs.tailscale}/bin/tailscaled"
                    "--tun=${interfaceName}"
                    "--state=${statePath}/tailscaled.state"
                    "--socket=${socketPath}"
                    "--port=${toString icfg.port}"
                    "-verbose=${toString (logLevelToVerbosity icfg.logLevel)}"
                  ];
                  RuntimeDirectory = "tailscale-${name}";
                  StateDirectory = "tailscale-${name}";
                  Restart = "on-failure";
                };
              };

              "tailscale-init-${name}" = {
                description = "Tailscale initialization for ${name} instance";
                after = [
                  "network-online.target"
                  "tailscaled-${name}.service"
                ];
                wants = [ "network-online.target" ];
                wantedBy = [ "multi-user.target" ];

                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  ExecStart = mkInitScript {
                    scriptName = "tailscale-init-${name}";
                    tailscaleCmd = "${pkgs.tailscale}/bin/tailscale --socket=${socketPath}";
                    authKeyPath = icfg.authKeyFile;
                    notConnectedMsg = "Not connected to login server, forcing reauthentication...";
                    loginServer = icfg.loginServer;
                    preAuthFlags = [ "--netfilter-mode=off" ];
                    extraFlags = [
                      (lib.optionalString icfg.acceptRoutes "--accept-routes")
                      (lib.optionalString (icfg.hostname != null) "--hostname=${icfg.hostname}")
                      (lib.optionalString icfg.exitNode "--advertise-exit-node --advertise-routes=0.0.0.0/0,::/0")
                    ];
                    useExitNode = icfg.useExitNode;
                  };
                };
              };
            }
          ) (lib.attrNames cfg.extraInstances)
        ))

        # Safety net: `tailscale up --reset` clears the configured exit node and
        # mkInitScript's re-set loop retries only ~60s before giving up WITHOUT
        # failing the unit. A slow boot (no wifi, Headscale unreachable, exit node
        # not yet in the netmap) would otherwise strand the host with no exit
        # node. This oneshot (driven by a 2-min timer below) re-applies it
        # whenever it is found missing.
        (lib.mkIf (cfg.enable && cfg.useExitNode != null) {
          tailscale-exit-node-ensure = {
            description = "Re-apply exit node ${cfg.useExitNode} when it is not active";
            after = [ "tailscale-init.service" ];
            path = [
              pkgs.tailscale
              pkgs.jq
            ];
            script = ''
              status=$(tailscale status --json 2>/dev/null || echo '{}')
              if [ "$(echo "$status" | jq -r '.BackendState // ""')" != "Running" ]; then
                echo "tailscale backend not running; nothing to do"
                exit 0
              fi
              if [ "$(echo "$status" | jq -r '.ExitNodeStatus.ID // ""')" != "" ]; then
                exit 0
              fi
              echo "no exit node active; setting ${cfg.useExitNode}"
              tailscale set --exit-node=${cfg.useExitNode}
            '';
            serviceConfig.Type = "oneshot";
          };
        })
      ];

      systemd.timers.tailscale-exit-node-ensure = lib.mkIf (cfg.enable && cfg.useExitNode != null) {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "2min";
          RandomizedDelaySec = "20s";
        };
      };
    }

    # Optional co-located DERP relay. `services.derp-server` is NOT part of
    # nixpkgs — it comes from an external flake input. We only emit this block
    # when that option is actually declared in your configuration; otherwise it
    # is skipped entirely (so importing this module without the derp-server
    # module still evaluates). If you want an exit node but have no derp-server
    # module, set `withoutDerp = true`. `mkIf false` would NOT be enough here:
    # a definition for an undeclared option is an eval error regardless of its
    # condition, hence the `optionalAttrs` existence guard.
    (lib.optionalAttrs (options.services ? derp-server) {
      services.derp-server = lib.mkIf (cfg.enable && cfg.exitNode && cfg.derperDomain != null) {
        enable = lib.mkDefault true;
        hostname = lib.mkDefault cfg.derperDomain;
        port = lib.mkDefault 8443;
        stunPort = lib.mkDefault 3478;
        verifyClients = lib.mkDefault true;
        acmeHost = lib.mkDefault (
          if cfg.derperAcmeHost != null then cfg.derperAcmeHost else cfg.derperDomain
        );
      };
    })
  ];
}
