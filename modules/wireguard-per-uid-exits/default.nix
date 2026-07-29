{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.wireguardExits;
  naming = cfg.naming;
  num = cfg.numbering;

  exitNames = lib.attrNames cfg.exits;
  declarationOrder = lib.imap0 (i: name: { inherit i name; }) exitNames;
  autoIndex = name: (lib.findFirst (x: x.name == name) null declarationOrder).i;

  mkExit =
    name:
    let
      e = cfg.exits.${name};
      i = if e.index != null then e.index else autoIndex name;
    in
    rec {
      inherit name i;
      exit = e;
      iface = "${naming.interfacePrefix}${name}";
      runDir = "/run/${naming.runtimeDirectory}/${name}";
      runtimeDirectory = "${naming.runtimeDirectory}/${name}";
      setupUnit = "${naming.setupUnitPrefix}-${name}";
      relayUnit = "${naming.relayUnitPrefix}-${name}";
      relayUser = "${naming.relayUserPrefix}-${name}";

      rtTable = num.routeTableBase + i;
      fwmark = num.fwmarkBase + i;
      tunnelFwmark = num.tunnelFwmarkBase + i;
      rulePriority = num.rulePriorityBase + i;
      relayUid = num.relayUidBase + i;

      pinList = lib.mapAttrsToList (pinName: pin: {
        inherit pinName;
        exitName = name;
        inherit (pin) uid uidRangeRule;
      }) e.pins;

      # The relay is itself nothing but a pin: a dedicated uid whose egress is
      # marked into this exit's table.
      markEntries =
        lib.optional e.socksRelay.enable {
          uid = relayUid;
          inherit fwmark tunnelFwmark;
        }
        ++ map (p: {
          inherit (p) uid;
          inherit fwmark tunnelFwmark;
        }) pinList;
    };

  exits = map mkExit exitNames;

  allPins = lib.concatMap (e: e.pinList) exits;
  uidRangePins = lib.imap0 (j: p: p // { j = j; }) (lib.filter (p: p.uidRangeRule.enable) allPins);

  markEntries = lib.concatMap (e: e.markEntries) exits;

  markRule =
    m:
    "meta skuid ${toString m.uid} meta mark != ${toString m.tunnelFwmark} meta mark set ${toString m.fwmark}";

  # The recursion guard is the `meta mark !=` clause. Continuation lines are
  # indented by a fixed string because nft does not care about whitespace and
  # the alternative is a second concatenation pass.
  nftRuleset = ''
    table inet ${naming.nftTable} {
      chain output {
        type route hook output priority mangle;
        ${lib.concatMapStringsSep "\n          " markRule markEntries}
      }
    }
  '';

  iptablesMarkRule =
    m:
    "ip46tables -t mangle -A OUTPUT -m owner --uid-owner ${toString m.uid} "
    + "-m mark ! --mark ${toString m.tunnelFwmark} -j MARK --set-mark ${toString m.fwmark}";

  iptablesUnmarkRule =
    m:
    "ip46tables -t mangle -D OUTPUT -m owner --uid-owner ${toString m.uid} "
    + "-m mark ! --mark ${toString m.tunnelFwmark} -j MARK --set-mark ${toString m.fwmark} || true";

  # Everything below the config selection is source-independent: parse the
  # WireGuard config out of $CONF, create the interface, and install this
  # exit's routing table + fwmark rule.
  setupTail = l: ''
    echo "$CONF" | grep -oP 'PrivateKey\s*=\s*\K.*' > "$RUN/private-key"
    chmod 400 "$RUN/private-key"

    ADDRESSES=$(echo "$CONF" | grep -oP 'Address\s*=\s*\K.*')
    IPV4=$(echo "$ADDRESSES" | tr ',' '\n' | grep -v ':' | head -1 | tr -d ' ')

    PEER_PUB=$(echo "$CONF" | grep -oP 'PublicKey\s*=\s*\K.*' | tr -d ' ')
    ENDPOINT=$(echo "$CONF" | grep -oP 'Endpoint\s*=\s*\K.*' | tr -d ' ')

    echo "$PEER_PUB" > "$RUN/peer-public-key"
    echo "$ENDPOINT" > "$RUN/endpoint"
    echo "$IPV4" > "$RUN/ipv4"

    ip link del "$IFACE" 2>/dev/null || true
    ip link add "$IFACE" type wireguard

    wg set "$IFACE" \
      fwmark ${toString l.tunnelFwmark} \
      private-key "$RUN/private-key" \
      peer "$PEER_PUB" \
        endpoint "$ENDPOINT" \
        allowed-ips "${l.exit.allowedIPs}" \
        persistent-keepalive ${toString l.exit.persistentKeepalive}

    ip addr add "$IPV4" dev "$IFACE"
    ip link set "$IFACE" up mtu ${toString l.exit.mtu}

    IPV4_BARE="''${IPV4%%/*}"
    TABLE=${toString l.rtTable}
    FWMARK=${toString l.fwmark}
    PRIO=${toString l.rulePriority}

    while ip -4 rule del priority "$PRIO" 2>/dev/null; do :; done
    ip route flush table "$TABLE" 2>/dev/null || true

    ip route add default dev "$IFACE" table "$TABLE"
    ip rule add fwmark "$FWMARK" lookup "$TABLE" priority "$PRIO"

    echo "wg interface $IFACE up (peer $ENDPOINT, src $IPV4_BARE, fwmark $FWMARK → table $TABLE)"
  '';

  bundleSetup = l: ''
    set -euo pipefail

    ZIP="${l.exit.configBundle.zipPath}"
    RUN="${l.runDir}"
    IFACE="${l.iface}"

    CONFIGS=$(unzip -l "$ZIP" '*.conf' | awk '/\.conf$/{print $NF}')

    FILTERED=""
    for conf in $CONFIGS; do
      base="$(basename "$conf")"
      ${lib.concatMapStringsSep "\n      " (pattern: ''
        case "$base" in
          ${pattern}.conf) FILTERED="$FILTERED $conf" ;;
        esac
      '') l.exit.configBundle.select}
    done
    FILTERED="''${FILTERED## }"

    if [ -z "$FILTERED" ]; then
      echo "no configs matched ${toString l.exit.configBundle.select}; available: $CONFIGS" >&2
      exit 1
    fi

    CHOSEN=$(echo "$FILTERED" | tr ' ' '\n' | shuf -n1)
    echo "selected ${cfg.providerLabel} config: $CHOSEN"

    CONF=$(unzip -p "$ZIP" "$CHOSEN")
  '';

  fileSetup = l: ''
    set -euo pipefail

    RUN="${l.runDir}"
    IFACE="${l.iface}"

    CONF=$(cat "${l.exit.configFile}")
  '';

  setupScript =
    l: (if l.exit.configBundle != null then bundleSetup l else fileSetup l) + "\n" + setupTail l;

  pinOpts =
    { ... }:
    {
      options = {
        uid = lib.mkOption {
          type = lib.types.int;
          example = 870;
          description = ''
            Numeric uid whose egress is pinned to this exit. It must be a
            *static* uid: the packet-marking rule is compiled into the
            firewall ruleset, so `DynamicUser = true` (whose uid is picked at
            unit start) can never be pinned this way.
          '';
        };

        uidRangeRule = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Also install `ip rule add uidrange <uid>-<uid> lookup <table>`.

              The mark rule alone is not enough for a daemon that does not bind
              to the tunnel interface itself: source-address selection happens
              during the route lookup at `connect()` time, *before* the output
              hook has stamped the mark, so the socket picks the host's normal
              source address and the packet then leaves the tunnel with a
              source the peer will not answer. A uid-matching policy rule makes
              the *route lookup itself* uid-aware, so the source address comes
              out of the tunnel too.

              Leave this off for processes that are told which interface to
              bind (`SO_BINDTODEVICE`, or an application-level `interface=`
              setting) — the mark rule is then sufficient.
            '';
          };
          priority = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            description = ''
              `ip rule` priority for the uidrange rule. Defaults to
              `numbering.uidRangeRulePriorityBase` plus an allocation index.
              Must be numerically lower (= consulted earlier) than the fwmark
              rules, and must not collide with another rule you manage.
            '';
          };
        };
      };
    };

  exitOpts =
    { ... }:
    {
      options = {
        index = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = null;
          example = 3;
          description = ''
            Explicit slot number for this exit. Every derived number (routing
            table, fwmark, tunnel fwmark, rule priority, relay uid) is
            `<base> + index`.

            When `null` the index is the exit's position in the *alphabetically
            sorted* attribute set — which means adding an exit whose name sorts
            early silently renumbers every exit after it. Pin the index by hand
            on any deployment where a number leaks into something durable
            (file ownership, an external module, a firewall rule you wrote).
          '';
        };

        configFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "/run/credentials/wireguard-exit-ams.service/conf";
          description = ''
            Runtime path of a WireGuard `.conf` file (INI: `PrivateKey`,
            `Address`, `PublicKey`, `Endpoint`).

            Deliberately `types.str`, not `types.path`: a `path` would be
            copied into the world-readable Nix store, taking the tunnel's
            private key with it. Point this at a decrypted secret,
            a `LoadCredential` destination, or a mount.
          '';
        };

        configBundle = lib.mkOption {
          default = null;
          description = ''
            Alternative to `configFile`: a provider-supplied zip of `.conf`
            files, one per server. One entry is picked at random on every
            (re)start of the setup unit, so restarting the unit re-rolls the
            server without changing any configuration.
          '';
          type = lib.types.nullOr (
            lib.types.submodule {
              options = {
                zipPath = lib.mkOption {
                  type = lib.types.str;
                  example = "/run/secrets/vpn-region.zip";
                  description = "Runtime path of the zip. `types.str` for the same reason as `configFile`.";
                };
                select = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ "*" ];
                  example = [ "xx-yyy-wg-*" ];
                  description = ''
                    Shell glob patterns (matched against the entry basename
                    minus the `.conf` suffix) narrowing which servers may be
                    picked. Defaults to every entry in the zip.
                  '';
                };
              };
            }
          );
        };

        allowedIPs = lib.mkOption {
          type = lib.types.str;
          default = "0.0.0.0/0";
          description = ''
            `AllowedIPs` for the peer. The default makes the tunnel a full
            exit. It is a *cryptographic routing* statement, not a route: the
            module never adds a default route to the main table, only to this
            exit's own table.
          '';
        };

        mtu = lib.mkOption {
          type = lib.types.int;
          default = 1280;
          description = ''
            Interface MTU. 1280 (the IPv6 minimum) is the value that survives
            every path; 1420 is the usual maximum for WireGuard over a 1500
            byte v4 path. If you raise it, expect the classic "TLS handshake
            completes, large responses hang" PMTU black hole.
          '';
        };

        persistentKeepalive = lib.mkOption {
          type = lib.types.int;
          default = 25;
          description = "Peer `PersistentKeepalive`, in seconds. Keeps the provider's NAT mapping alive.";
        };

        trustInterface = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Add the interface to `networking.firewall.trustedInterfaces`.

            Off by default on purpose: a commercial exit is an *untrusted*
            network, and `trustedInterfaces` accepts everything arriving on it
            without consulting the input chain. Turn it on only when something
            has to accept inbound connections through the tunnel (a torrent
            client with a forwarded port, for example) and you have accounted
            for every listening socket on the host.
          '';
        };

        socksRelay = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Run a SOCKS5 listener on loopback whose own uid is pinned to this
              exit, turning the tunnel into an address that unprivileged,
              unmodified clients can point at. This is the cheapest way to hand
              *one* exit to many consumers without giving each of them a uid.
            '';
          };
          port = lib.mkOption {
            type = lib.types.nullOr lib.types.port;
            default = null;
            example = 10810;
            description = "Loopback port for the relay. Required when `socksRelay.enable` is set; must be unique across exits.";
          };
          package = lib.mkPackageOption pkgs "gost" { };
        };

        pins = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule pinOpts);
          default = { };
          example = lib.literalExpression ''
            {
              torrent = {
                uid = 870;
                uidRangeRule.enable = true;
              };
            }
          '';
          description = "Extra uids pinned to this exit, beyond the relay's own.";
        };

        extraSetupServiceConfig = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          example = lib.literalExpression ''{ LoadCredential = "conf:/run/agenix/vpn-ams"; }'';
          description = ''
            Merged into the setup unit's `serviceConfig`. The intended use is
            `LoadCredential`, paired with a `configFile` pointing at
            `/run/credentials/<unit>/<id>`.
          '';
        };
      };
    };
in
{
  options.services.wireguardExits = {
    enable = lib.mkEnableOption "N simultaneous WireGuard exits with per-uid egress pinning";

    providerLabel = lib.mkOption {
      type = lib.types.str;
      default = "VPN";
      example = "AcmeVPN";
      description = ''
        Human label for the tunnel provider. It appears in unit `Description=`
        strings and in log lines. Unit descriptions are part of the unit file,
        so changing this produces a system-closure diff — pick it once when
        adopting the module.
      '';
    };

    markBackend = lib.mkOption {
      type = lib.types.enum [
        "nftables"
        "iptables"
        "manual"
      ];
      default = if config.networking.nftables.enable then "nftables" else "iptables";
      defaultText = lib.literalExpression ''if config.networking.nftables.enable then "nftables" else "iptables"'';
      description = ''
        Which firewall backend carries the uid → fwmark rules.

        `nftables` appends an own table to `networking.nftables.ruleset`.
        `iptables` uses `networking.firewall.extraCommands`, which the
        nftables-based firewall hard-rejects
        (`nixos/modules/services/networking/firewall-nftables.nix:65`), so the
        two are mutually exclusive and an assertion enforces it.

        `manual` emits no firewall rules at all and leaves `nftRuleset` for you
        to place. Use it when another module on the host also appends to
        `networking.nftables.ruleset`: `mkAfter` chunks are concatenated in
        module *collection* order, so a table emitted from an imported module
        lands after every table emitted by the importing module's siblings.
        The resulting ruleset behaves identically but is a different file, and
        therefore a different system closure.
      '';
    };

    naming = {
      interfacePrefix = lib.mkOption {
        type = lib.types.str;
        default = "wg-";
        description = "Prefix for the WireGuard link name. `prefix + exit name` must be ≤ 15 characters (`IFNAMSIZ`).";
      };
      setupUnitPrefix = lib.mkOption {
        type = lib.types.str;
        default = "wireguard-exit";
        description = "Prefix for the per-exit setup unit (`<prefix>-<exit>.service`).";
      };
      relayUnitPrefix = lib.mkOption {
        type = lib.types.str;
        default = "wireguard-exit-relay";
        description = "Prefix for the per-exit SOCKS relay unit.";
      };
      relayUserPrefix = lib.mkOption {
        type = lib.types.str;
        default = "wireguard-exit-relay";
        description = "Prefix for the per-exit relay's system user.";
      };
      relayGroup = lib.mkOption {
        type = lib.types.str;
        default = "wireguard-exit-relay";
        description = "Group shared by every relay user.";
      };
      runtimeDirectory = lib.mkOption {
        type = lib.types.str;
        default = "wireguard-exits";
        description = "`RuntimeDirectory` prefix; the per-exit state lives in `/run/<this>/<exit>`.";
      };
      nftTable = lib.mkOption {
        type = lib.types.str;
        default = "wireguard-exits-mark";
        description = "Name of the `table inet` holding the marking chain.";
      };
    };

    numbering = {
      routeTableBase = lib.mkOption {
        type = lib.types.int;
        default = 200;
        description = "Routing table id of exit *i* is `base + i`. Stay clear of 253-255 (default/main/local) and of anything in `/etc/iproute2/rt_tables`.";
      };
      fwmarkBase = lib.mkOption {
        type = lib.types.int;
        default = 200;
        description = "Packet mark that selects exit *i* is `base + i`.";
      };
      tunnelFwmarkBase = lib.mkOption {
        type = lib.types.int;
        default = 400;
        description = ''
          Mark that WireGuard itself stamps on the *encrypted outer* packets of
          exit *i* (`wg set <if> fwmark`). Must not overlap the `fwmarkBase`
          block: the marking rule's recursion guard is precisely
          `meta mark != <this>`.
        '';
      };
      rulePriorityBase = lib.mkOption {
        type = lib.types.int;
        default = 2000;
        description = "`ip rule` priority for exit *i* is `base + i`.";
      };
      relayUidBase = lib.mkOption {
        type = lib.types.int;
        default = 850;
        description = "Static uid of exit *i*'s relay user is `base + i`. Pick a free block; NixOS's own static ids are listed in `nixos/modules/misc/ids.nix`.";
      };
      uidRangeRulePriorityBase = lib.mkOption {
        type = lib.types.int;
        default = 1500;
        description = "First `ip rule` priority handed to `pins.*.uidRangeRule`. Must be lower than `rulePriorityBase`.";
      };
    };

    exits = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule exitOpts);
      default = { };
      description = ''
        Named exits. Each one becomes an interface, a routing table, a fwmark,
        an `ip rule`, and (optionally) a SOCKS relay and a set of pinned uids.
        Traffic that is not pinned to any exit is untouched and leaves by the
        host's normal default route.
      '';
    };

    nftRuleset = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      visible = false;
      description = ''
        The computed `table inet <naming.nftTable>` holding the marking chain.
        Emitted automatically unless `markBackend = "manual"`, in which case
        assign it yourself, e.g.
        `networking.nftables.ruleset = lib.mkAfter config.services.wireguardExits.nftRuleset;`.
      '';
    };

    slots = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      readOnly = true;
      visible = false;
      description = ''
        Computed numbering, keyed by exit name: `index`, `interface`,
        `routeTable`, `fwmark`, `tunnelFwmark`, `rulePriority`, `relayUid`,
        `runtimeDir`, `setupUnit`.

        Read these from other modules instead of recomputing `base + index` by
        hand — an out-of-tree copy of that arithmetic is how a service ends up
        silently routed through the wrong country after someone adds an exit.
      '';
    };
  };

  config = lib.mkMerge [
    {
      # Defined unconditionally (and outside the mkIf) so that a consumer
      # module can read it without knowing whether this module is enabled, and
      # because a readOnly option may not carry a `default` — lib/modules.nix
      # counts the default as one of the definitions it forbids stacking.
      services.wireguardExits.nftRuleset = nftRuleset;

      services.wireguardExits.slots = lib.listToAttrs (
        map (
          l:
          lib.nameValuePair l.name {
            inherit (l)
              fwmark
              tunnelFwmark
              rulePriority
              relayUid
              setupUnit
              ;
            index = l.i;
            interface = l.iface;
            routeTable = l.rtTable;
            runtimeDir = l.runDir;
          }
        ) exits
      );
    }

    (lib.mkIf (cfg.enable && cfg.exits != { }) {
      assertions =
        map (l: {
          assertion = builtins.stringLength l.iface <= 15;
          message = "services.wireguardExits: interface '${l.iface}' exceeds the 15-character IFNAMSIZ limit; shorten the exit name '${l.name}' or the interfacePrefix.";
        }) exits
        ++ map (l: {
          assertion = (l.exit.configFile == null) != (l.exit.configBundle == null);
          message = "services.wireguardExits.exits.${l.name}: set exactly one of configFile or configBundle.";
        }) exits
        ++ map (l: {
          assertion = !l.exit.socksRelay.enable || l.exit.socksRelay.port != null;
          message = "services.wireguardExits.exits.${l.name}: socksRelay.enable requires socksRelay.port.";
        }) exits
        ++ [
          {
            assertion = cfg.markBackend != "nftables" || config.networking.nftables.enable;
            message = "services.wireguardExits: markBackend = \"nftables\" requires networking.nftables.enable = true.";
          }
          {
            assertion = cfg.markBackend != "iptables" || !config.networking.nftables.enable;
            message = "services.wireguardExits: markBackend = \"iptables\" cannot be used with the nftables firewall (see firewall-nftables.nix:65).";
          }
          {
            assertion = lib.length (lib.unique (map (m: m.uid) markEntries)) == lib.length markEntries;
            message = "services.wireguardExits: a uid is pinned to more than one exit; each uid can only have one egress.";
          }
          {
            assertion =
              let
                indices = map (l: l.i) exits;
              in
              lib.length (lib.unique indices) == lib.length indices;
            message = "services.wireguardExits: two exits share the same index; every derived number would collide.";
          }
          {
            assertion =
              let
                ports = map (l: l.exit.socksRelay.port) (lib.filter (l: l.exit.socksRelay.enable) exits);
              in
              lib.length (lib.unique ports) == lib.length ports;
            message = "services.wireguardExits: two exits share a socksRelay.port.";
          }
        ];

      networking.firewall.trustedInterfaces = map (l: l.iface) (
        lib.filter (l: l.exit.trustInterface) exits
      );

      users.groups = lib.mkIf (lib.any (l: l.exit.socksRelay.enable) exits) {
        ${naming.relayGroup} = { };
      };

      users.users = lib.listToAttrs (
        map (
          l:
          lib.nameValuePair l.relayUser {
            isSystemUser = true;
            uid = l.relayUid;
            group = naming.relayGroup;
          }
        ) (lib.filter (l: l.exit.socksRelay.enable) exits)
      );

      networking.nftables.ruleset = lib.mkIf (cfg.markBackend == "nftables") (lib.mkAfter cfg.nftRuleset);

      networking.firewall.extraCommands = lib.mkIf (cfg.markBackend == "iptables") (
        lib.mkAfter (lib.concatMapStringsSep "\n" iptablesMarkRule markEntries)
      );

      networking.firewall.extraStopCommands = lib.mkIf (cfg.markBackend == "iptables") (
        lib.mkAfter (lib.concatMapStringsSep "\n" iptablesUnmarkRule markEntries)
      );

      systemd.services = lib.mkMerge (
        map (
          l:
          {
            ${l.setupUnit} = {
              description = "${cfg.providerLabel} config extract + WireGuard setup (${l.name})";
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];
              wantedBy = [ "multi-user.target" ];

              path =
                lib.optional (l.exit.configBundle != null) pkgs.unzip
                ++ (with pkgs; [
                  coreutils
                  wireguard-tools
                  iproute2
                  gawk
                  gnugrep
                ]);

              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                RuntimeDirectory = l.runtimeDirectory;
                RuntimeDirectoryMode = "0700";
              }
              // l.exit.extraSetupServiceConfig;

              script = setupScript l;
            };
          }
          // lib.optionalAttrs l.exit.socksRelay.enable {
            ${l.relayUnit} = {
              description = "SOCKS5 relay through ${l.iface} (${cfg.providerLabel} ${l.name})";
              after = [ "${l.setupUnit}.service" ];
              requires = [ "${l.setupUnit}.service" ];
              wantedBy = [ "multi-user.target" ];

              serviceConfig = {
                ExecStart = "${l.exit.socksRelay.package}/bin/gost -L 'socks5://127.0.0.1:${toString l.exit.socksRelay.port}?interface=${l.iface}'";
                User = l.relayUser;
                Group = naming.relayGroup;
                Restart = "always";
                RestartSec = 3;
              };
            };
          }
        ) exits
        ++ map (
          p:
          let
            l = lib.findFirst (x: x.name == p.exitName) null exits;
            prio =
              if p.uidRangeRule.priority != null then
                p.uidRangeRule.priority
              else
                num.uidRangeRulePriorityBase + p.j;
          in
          {
            "${naming.setupUnitPrefix}-pin-${p.exitName}-${p.pinName}" = {
              description = "uidrange ip rule pinning uid ${toString p.uid} to ${l.iface}";
              wantedBy = [ "multi-user.target" ];
              after = [ "${l.setupUnit}.service" ];
              requires = [ "${l.setupUnit}.service" ];
              path = [ pkgs.iproute2 ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = ''
                set -eu
                while ip -4 rule del priority ${toString prio} 2>/dev/null; do :; done
                ip -4 rule add uidrange ${toString p.uid}-${toString p.uid} \
                  lookup ${toString l.rtTable} priority ${toString prio}
              '';
            };
          }
        ) uidRangePins
      );
    })
  ];
}
