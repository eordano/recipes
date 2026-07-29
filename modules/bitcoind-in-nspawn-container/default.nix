# bitcoind-in-nspawn-container
#
# Run an internet-facing bitcoind inside a privateNetwork systemd-nspawn
# container, with the chain data bind-mounted from the host so a full sync
# survives container rebuilds. The service user is declared with the SAME
# uid/gid on BOTH sides of the bind mount so on-disk ownership stays valid
# across the container boundary.
#
# Import this module and set `services.bitcoindContainer.enable = true;`.
#
# See README.md for the traps this encodes (shutdown timeout, DNS, W^X).

{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.bitcoindContainer;

  # bitcoind's own CLI convention for booleans is 1/0, NOT true/false — it
  # does not parse the words "true"/"false" as a boolean at all.
  settingValueToStr =
    v:
    if isBool v then
      (if v then "1" else "0")
    else if isInt v then
      toString v
    else if isString v then
      v
    else
      throw "services.bitcoindContainer.settings: unsupported value type (${builtins.typeOf v}) for a setting; use bool, int, str, or a list of those";

  # A list value repeats the flag once per element, matching bitcoind's
  # convention for "list" args such as -rpcallowip/-connect/-addnode.
  settingsToArgs =
    settings:
    concatLists (
      mapAttrsToList (
        name: value:
        if isList value then
          map (v: "-${name}=${settingValueToStr v}") value
        else
          [ "-${name}=${settingValueToStr value}" ]
      ) settings
    );
in
{
  options.services.bitcoindContainer = {
    enable = mkEnableOption "bitcoind running inside an isolated nspawn container";

    name = mkOption {
      type = types.str;
      default = "bitcoind";
      description = ''
        Base name used for the nspawn container, the host- and container-side
        service user/group, and the systemd bitcoind service unit. Change it
        only if you need to coexist with, or extend, resources under a specific
        name (e.g. a host that attaches extra bind mounts and companion services
        to `containers.<name>` and orders against `<name>.service`).
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.bitcoin;
      defaultText = literalExpression "pkgs.bitcoin";
      description = "The bitcoind package to run inside the container.";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/bitcoind";
      description = ''
        Host directory holding the blockchain data and configuration. It is
        bind-mounted into the container at /data. Put it on persistent storage;
        a full mainnet sync is hundreds of GiB and you do not want to redo it
        when the container is rebuilt.
      '';
    };

    uid = mkOption {
      type = types.int;
      default = 1320;
      description = ''
        User ID for the bitcoind service user. It MUST be identical on the host
        and inside the container, otherwise the files under dataDir will appear
        owned by the wrong user on one side of the bind mount.
      '';
    };

    gid = mkOption {
      type = types.int;
      default = 1320;
      description = ''
        Group ID for the bitcoind service group. Like uid, it must match on both
        sides of the bind mount.
      '';
    };

    network = mkOption {
      type = types.enum [
        "mainnet"
        "testnet"
        "regtest"
      ];
      default = "mainnet";
      description = "Bitcoin network to connect to.";
    };

    rpc = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable the bitcoind JSON-RPC server.";
      };

      port = mkOption {
        type = types.port;
        default = 8332;
        description = "bitcoind RPC port (opened in the container firewall when RPC is enabled).";
      };

      allowedIPs = mkOption {
        type = types.listOf types.str;
        default = [ "127.0.0.1" ];
        example = [ "192.168.203.1" ];
        description = ''
          IPs/subnets passed to -rpcallowip. To reach RPC from the host, allow
          the container-side or host-side veth address, not just loopback.
        '';
      };
    };

    containerNetwork = {
      hostAddress = mkOption {
        type = types.str;
        default = "192.168.203.1";
        description = ''
          Host side of the container's veth pair. This doubles as the
          container's only nameserver (see below), so the host must be able to
          resolve DNS on this address.
        '';
      };
      localAddress = mkOption {
        type = types.str;
        default = "192.168.203.2";
        description = "Container side of the veth pair.";
      };
    };

    stopTimeoutSec = mkOption {
      type = types.int;
      default = 300;
      description = ''
        TimeoutStopSec for bitcoind. On shutdown bitcoind flushes its UTXO set
        (chainstate) to disk, which can take minutes on a large node. If systemd
        SIGKILLs it before the flush completes you can corrupt the chainstate and
        force a lengthy reindex. Keep this generously long.
      '';
    };

    settings = mkOption {
      type = types.submodule {
        freeformType = types.attrsOf (
          types.oneOf [
            types.bool
            types.int
            types.str
            (types.listOf (
              types.oneOf [
                types.bool
                types.int
                types.str
              ]
            ))
          ]
        );
      };
      default = { };
      example = literalExpression ''
        {
          # keys the typed options above do not model at all
          maxconnections = 40;
          dbcache = 4096;
          blocksonly = true;                          # -> -blocksonly=1
          whitelist = [ "192.168.203.0/24" "10.0.0.5" ]; # -> repeated -whitelist=
        }
      '';
      description = ''
        Free-form bitcoind settings for anything the typed options above do
        not cover, so an adopter never has to fork this module for a flag its
        author did not anticipate. Each attribute becomes a bitcoind
        `-key=value` command-line argument:

        - `bool` becomes `1`/`0` — bitcoind's own convention, NOT `true`/`false`.
        - `int` and `str` are stringified as-is.
        - a list repeats the flag once per element (bitcoind's convention for
          "list" args like `-rpcallowip`/`-connect`/`-addnode`/`-whitelist`).

        Precedence: `settings` is rendered AFTER the typed options above
        (`network`, `rpc.*`, ...) and BEFORE `extraArgs`. bitcoind's argument
        parser keeps the LAST occurrence of a scalar flag, so a key in
        `settings` overrides the same key derived from a typed option, and a
        key in `extraArgs` overrides the same key set via `settings`. List-style
        flags do not override this way — occurrences accumulate — so e.g.
        `rpc.allowedIPs` and `settings.rpcallowip` would both take effect
        rather than one replacing the other.
      '';
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "-zmqpubrawblock=tcp://127.0.0.1:28332" ];
      description = ''
        Extra command-line arguments for bitcoind, rendered last (after
        `settings`), so this is the final override if you need one. Prefer
        `settings` for plain `-key=value`/repeated-key flags; `extraArgs`
        still accepts anything, including flags with no value. Note that the
        service runs with MemoryDenyWriteExecute, so any argument that pulls
        in a JIT plugin will fault — disable the hardening if you need one.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Host-side declaration of the service user. Declared with the same uid/gid
    # as inside the container so the bind-mounted data has consistent ownership.
    users = {
      users.${cfg.name} = {
        uid = cfg.uid;
        isSystemUser = true;
        group = cfg.name;
        description = "bitcoind node service user";
        home = cfg.dataDir;
      };
      groups.${cfg.name}.gid = cfg.gid;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 ${cfg.name} ${cfg.name} - -"
    ];

    containers.${cfg.name} = {
      autoStart = true;
      # privateNetwork gives the container its own network namespace: the
      # internet-facing daemon cannot reach the host's other services.
      privateNetwork = true;
      inherit (cfg.containerNetwork) hostAddress localAddress;

      config =
        { ... }:
        let
          bitcoindArgs = [
            "-datadir=/data"
            "-printtoconsole"
          ]
          ++ optional (cfg.network != "mainnet") "-${cfg.network}"
          ++ optionals cfg.rpc.enable (
            [
              "-server"
              "-rpcport=${toString cfg.rpc.port}"
              # Without -rpcbind, -rpcallowip alone makes bitcoind bind RPC on ALL
              # container interfaces (0.0.0.0/::) and act only as an IP filter. Bind
              # explicitly to loopback + the container-side veth (the address the
              # host reaches RPC on) so the socket is not exposed on every address.
              "-rpcbind=127.0.0.1"
              "-rpcbind=${cfg.containerNetwork.localAddress}"
            ]
            # -rpcallowip is repeatable and each value parses as ONE subnet
            # spec; there is no comma-separated form. Emit one flag per entry,
            # exactly as settingsToArgs does for list-valued settings.
            ++ map (ip: "-rpcallowip=${ip}") cfg.rpc.allowedIPs
          )
          ++ settingsToArgs cfg.settings
          ++ cfg.extraArgs;
        in
        {
          nixpkgs.pkgs = pkgs;
          system.stateVersion = "24.05";

          # Same uid/gid as the host user — this is the whole point.
          users.users.${cfg.name} = {
            uid = cfg.uid;
            isSystemUser = true;
            home = "/data";
            group = cfg.name;
            description = "bitcoind node service user";
          };
          users.groups.${cfg.name}.gid = cfg.gid;

          networking = {
            # With privateNetwork the container has no inherited resolver. Its
            # only route out is the host side of the veth, so point DNS there;
            # the host must actually resolve for it.
            nameservers = [ cfg.containerNetwork.hostAddress ];
            firewall = {
              enable = true;
              allowedTCPPorts = optionals cfg.rpc.enable [ cfg.rpc.port ];
            };
          };

          systemd.services.${cfg.name} = {
            description = "bitcoind node";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];

            serviceConfig = {
              Type = "simple";
              User = cfg.name;
              Group = cfg.name;
              ExecStart = "${cfg.package}/bin/bitcoind ${concatStringsSep " " bitcoindArgs}";
              Restart = "on-failure";
              TimeoutStartSec = "0";
              # Give bitcoind time to flush the UTXO set on stop — see option doc.
              TimeoutStopSec = toString cfg.stopTimeoutSec;

              PrivateTmp = true;
              ProtectSystem = "full";
              NoNewPrivileges = true;
              MemoryDenyWriteExecute = true;
            };
          };

          environment.systemPackages = [ cfg.package ];
        };

      bindMounts = {
        "/data" = {
          hostPath = cfg.dataDir;
          isReadOnly = false;
        };
      };
    };
  };
}
