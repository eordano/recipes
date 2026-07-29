# patroni-ha-cluster
#
# An opinionated NixOS wrapper around the upstream `services.patroni` module for
# running a PostgreSQL HA cluster whose etcd voting quorum lives in ONE region.
# A member outside that region joins as a `nofailover` client so a WAN flap can
# never lose quorum or trigger a spurious election, and a coexistence mode lets
# Patroni share a host with an unrelated local PostgreSQL without fighting over
# the runtime socket directory.
#
# All topology is passed in as plain module options — there is no external
# single-source-of-truth import, so this is a drop-in others can wire to their
# own inventory (a NixOS flake's node list, terraform output, etc.).
#
# See README.md for the why, the traps, and a promotion runbook sketch.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.services.patroni-cluster;

  # pg_hba scram rules for every trusted network CIDR the caller declares.
  networkHba = lib.concatMap (cidr: [
    "host replication ${cfg.replicationUsername} ${cidr} scram-sha-256"
    "host all all ${cidr} scram-sha-256"
  ]) cfg.trustedNetworks;
in
{
  options.modules.services.patroni-cluster = {
    enable = lib.mkEnableOption "Patroni PostgreSQL HA cluster node";

    # ---- topology (pass these in from your own inventory) -------------------

    scope = lib.mkOption {
      type = lib.types.str;
      default = "postgres-cluster";
      description = ''
        Patroni cluster scope. MUST be identical on every member of the same
        cluster and distinct from any other cluster sharing the same etcd DCS.
      '';
    };

    nodeName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Unique Patroni member name for this node.";
    };

    softwareWatchdog = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Arm the softdog watchdog on the leader so a wedged primary fences
        itself.

        Off by default because the fence is a whole-machine reboot, armed
        with only `ttl - safety_margin` (25s at the defaults) of slack. Any
        stall longer than that — a basebackup to a slow replica, heavy I/O,
        a GPU driver hiccup — reboots the host with no console output and no
        journal entry, which looks exactly like a hardware failure. Enable it
        only where a split brain is costlier than an unexplained reboot, and
        raise `ttl` first.
      '';
    };

    clonefrom = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Offer this member as a preferred source for other members' initial
        clone. Useful where the leader sits behind a weak uplink: a clone is
        several GB, and pulling it from a well-connected replica spares both
        the leader's link and the leader itself.
      '';
    };

    replicatefrom = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "bee";
      description = ''
        Stream from this member instead of the leader (cascading replication).
        Point a member at a topologically closer replica when the path to the
        leader is the slow link. Patroni falls back to the leader if the named
        member is unavailable.
      '';
    };

    basebackup = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        checkpoint = "spread";
        "max-rate" = "20M";
      };
      description = ''
        Options passed to `pg_basebackup` when this node clones from the
        leader.

        Patroni's own default is `checkpoint: fast`, which makes the LEADER
        run an immediate full checkpoint the moment a replica starts cloning
        — a synchronous I/O burst on the one node you can least afford to
        stall. `spread` amortises it instead, and `max-rate` bounds the read
        the clone can pull. Both trade clone speed for leader stability.
      '';
    };

    nodeIpWaitSeconds = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 60;
      description = ''
        How long to wait at startup for {option}`nodeIp` to appear on some
        interface before starting Patroni anyway.

        Set to 0 to disable the wait entirely. Waiting is a no-op on a host
        where the address is statically configured; it only matters when an
        overlay network brings it up asynchronously.
      '';
    };

    nodeIp = lib.mkOption {
      type = lib.types.str;
      example = "10.0.0.11";
      description = ''
        The address THIS node advertises to peers and to the Patroni REST API.
        Use a stable private/overlay address that every cluster member and the
        connection router can reach.
      '';
    };

    otherNodesIps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "10.0.0.12"
        "10.0.0.13"
      ];
      description = "Advertised addresses of the OTHER Patroni members.";
    };

    etcdHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [
        "10.0.0.11:2379"
        "10.0.0.12:2379"
        "10.0.0.13:2379"
      ];
      description = ''
        `host:port` endpoints of the etcd nodes that form the voting DCS.

        KEY INVARIANT: list ONLY the etcd nodes in your quorum region. A member
        in another region should still point here (it uses etcd purely as a
        client) — that is what pins the quorum to one region and stops a WAN
        partition from calling an election. Do NOT add a co-located etcd on the
        remote member to this list.
      '';
    };

    nofailover = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Tag this member `nofailover`. Set true on any member outside the quorum
        region (typically a WAN-distant async replica): Patroni will never
        auto-promote it, so promoting it becomes a deliberate DR action.
      '';
    };

    pgPort = lib.mkOption {
      type = lib.types.port;
      default = 5432;
      description = "PostgreSQL port Patroni manages.";
    };

    restApiPort = lib.mkOption {
      type = lib.types.port;
      default = 8008;
      description = ''
        Patroni REST API port (health checks, patronictl, routers).

        NOTE: this API has NO authentication by default and, besides read-only
        health checks, serves state-changing endpoints (/restart, /switchover,
        /failover, /reinitialize). Anything that can reach this port can trigger
        them. Do not expose it beyond the hosts that actually need it (routers /
        patronictl operators); see the README security note.
      '';
    };

    # ---- local instance ------------------------------------------------------

    disableSystemPostgresql = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Force-disable the NixOS-managed `services.postgresql` so Patroni owns
        the only PostgreSQL on the host. Default (true) is what a dedicated
        cluster member wants.

        Set FALSE on a host that also runs an unrelated PostgreSQL (e.g. an app
        bundling its own PG on another port). In coexistence mode Patroni moves
        BOTH its `unix_socket_directories` GUC and its systemd `RuntimeDirectory`
        to `/run/patroni`, so the two instances never fight over the same socket
        dir or runtime-directory lifecycle. See README.
      '';
    };

    postgresqlPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.postgresql_17;
      defaultText = lib.literalExpression "pkgs.postgresql_17";
      description = "PostgreSQL package Patroni runs. Must match across members.";
    };

    postgresqlDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/patroni/pg";
      description = ''
        PGDATA directory. Point at a persistent, host-local path. On systems
        that wipe non-persisted state (e.g. impermanence setups) put it on the
        persistent mount.
      '';
    };

    superuserPasswordFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a file containing ONLY the postgres superuser password. Loaded
        as a systemd environment file at runtime, so the secret never lands in
        the world-readable Nix store. Wire this to your secret manager
        (sops-nix, or any tool that materializes a runtime file) — do not
        inline the password here.
      '';
    };

    replicationPasswordFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a file containing ONLY the replication user's password. Same
        out-of-store handling as `superuserPasswordFile`.
      '';
    };

    superuserUsername = lib.mkOption {
      type = lib.types.str;
      default = "postgres";
      description = "Superuser role name.";
    };

    replicationUsername = lib.mkOption {
      type = lib.types.str;
      default = "replicator";
      description = "Replication role name.";
    };

    listenAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        cfg.nodeIp
        "127.0.0.1"
      ];
      defaultText = lib.literalExpression ''[ config.modules.services.patroni-cluster.nodeIp "127.0.0.1" ]'';
      description = ''
        Addresses PostgreSQL listens on. Defaults to the advertised node IP plus
        loopback. Set to [ "0.0.0.0" ] (or add a bridge-gateway IP) on hosts
        where local containers / microvms connect over a bridge subnet rather
        than loopback or the overlay.
      '';
    };

    trustedNetworks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "10.0.0.0/24" ];
      description = ''
        CIDR ranges allowed to connect (all databases + replication) with
        scram-sha-256 auth. Put your private/overlay network here. Localhost is
        always permitted. Layer host-specific rules on with `extraPgHba`.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open pgPort + restApiPort in the firewall.";
    };

    firewallInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "wg0";
      description = ''
        When `openFirewall` is set: restrict the port openings to this single
        interface (e.g. your overlay/VPN interface). Leave null to open globally
        — strongly discouraged for a database. Ignored when openFirewall is
        false.
      '';
    };

    extraPgHba = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra pg_hba lines appended after the generated rules.";
    };

    extraPgParameters = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra runtime postgresql.conf parameters (merged in).";
    };
  };

  config = lib.mkIf cfg.enable {
    # In dedicated mode, take PostgreSQL entirely away from NixOS so only
    # Patroni drives it.
    services.postgresql.enable = lib.mkIf cfg.disableSystemPostgresql (lib.mkForce false);

    services.patroni = {
      enable = true;
      scope = cfg.scope;
      name = cfg.nodeName;
      nodeIp = cfg.nodeIp;
      otherNodesIps = cfg.otherNodesIps;
      restApiPort = cfg.restApiPort;
      postgresqlPackage = cfg.postgresqlPackage;
      postgresqlDataDir = cfg.postgresqlDataDir;
      postgresqlPort = cfg.pgPort;

      softwareWatchdog = cfg.softwareWatchdog;

      environmentFiles = {
        PATRONI_SUPERUSER_PASSWORD = cfg.superuserPasswordFile;
        PATRONI_REPLICATION_PASSWORD = cfg.replicationPasswordFile;
      };

      settings = {
        etcd3.hosts = lib.concatStringsSep "," cfg.etcdHosts;

        tags = {
          inherit (cfg) nofailover clonefrom;
        }
        // lib.optionalAttrs (cfg.replicatefrom != null) { inherit (cfg) replicatefrom; };

        # WARNING: everything under bootstrap.* is written to the DCS ONCE, at
        # cluster init. On a LIVE cluster editing this Nix does nothing — change
        # these with `patronictl edit-config`. See README.
        bootstrap = {
          dcs = {
            ttl = 30;
            loop_wait = 10;
            # etcd3 client divides retry_timeout across hosts; keep it generous
            # enough that one WAN hiccup can't expire a remote member's key
            # (e.g. 20s over 3 etcd nodes ≈ 6.7s/host).
            retry_timeout = 20;
            maximum_lag_on_failover = 1048576;
            # A replica that loses the DCS keeps serving reads instead of
            # demoting itself — critical for a WAN-distant member.
            failsafe_mode = true;
            postgresql = {
              use_pg_rewind = true;
              use_slots = true;
              parameters = {
                max_connections = 200;
                wal_level = "replica";
                hot_standby = "on";
                max_wal_senders = 10;
                max_replication_slots = 10;
                tcp_keepalives_idle = 300;
                tcp_keepalives_interval = 60;
              };
            };
          };
          initdb = [
            { encoding = "UTF8"; }
            "data-checksums"
          ];
        };

        postgresql = {
          listen = lib.mkForce "${lib.concatStringsSep "," cfg.listenAddresses}:${toString cfg.pgPort}";
          authentication = {
            replication.username = cfg.replicationUsername;
            superuser.username = cfg.superuserUsername;
          };
          pg_hba = [
            "local all all peer"
            "host all all 127.0.0.1/32 scram-sha-256"
            "host replication ${cfg.replicationUsername} 127.0.0.1/32 scram-sha-256"
          ]
          ++ networkHba
          ++ cfg.extraPgHba;
          basebackup = cfg.basebackup;
          parameters = {
            # Coexistence: move Patroni's socket off the default dir so it never
            # collides with an unrelated local PostgreSQL on the same host.
            unix_socket_directories =
              if cfg.disableSystemPostgresql then "/run/postgresql" else "/run/patroni";
          }
          // cfg.extraPgParameters;
        };
      };
    };

    networking.firewall = lib.mkIf cfg.openFirewall (
      let
        ports = [
          cfg.pgPort
          cfg.restApiPort
        ];
      in
      if cfg.firewallInterface != null then
        { interfaces.${cfg.firewallInterface}.allowedTCPPorts = ports; }
      else
        { allowedTCPPorts = ports; }
    );

    systemd.services.patroni = {
      serviceConfig = {
        # Keep systemd's RuntimeDirectory lifecycle aligned with the socket dir
        # chosen above, so coexistence mode owns /run/patroni cleanly.
        RuntimeDirectory = if cfg.disableSystemPostgresql then "postgresql" else "patroni";
        StateDirectory = "patroni";
      };

      # Patroni binds its REST API to nodeIp at startup. When that address lives
      # on an overlay interface (WireGuard, Tailscale, a bridge brought up by
      # another unit), it does not exist yet at the moment `network-online`
      # fires, and the bind dies with EADDRNOTAVAIL. systemd then restarts into
      # the same race until it hits the start limit and gives up for good --
      # which looks like "Patroni is broken on this host" rather than "the
      # overlay was five seconds late".
      #
      # Waiting for the address itself is the precise condition, and it does not
      # care which technology supplies it.
      preStart = ''
        for _ in $(seq 1 ${toString cfg.nodeIpWaitSeconds}); do
          if ${pkgs.iproute2}/bin/ip -o addr show to ${cfg.nodeIp} 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q .; then
            exit 0
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done
        echo "patroni: ${cfg.nodeIp} is not assigned to any interface after ${toString cfg.nodeIpWaitSeconds}s; starting anyway" >&2
      '';
    };

    systemd.tmpfiles.rules = [
      "d ${dirOf cfg.postgresqlDataDir} 0700 patroni patroni - -"
      "d ${cfg.postgresqlDataDir}        0700 patroni patroni - -"
    ];
  };
}
