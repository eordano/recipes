# etcd-cluster-over-tailnet
#
# Run an etcd cluster whose peer + client traffic rides ONLY a private mesh
# interface (WireGuard / Tailscale / a VLAN) and never touches the public
# firewall. Every etcd URL is derived from a single topology attrset so that
# adding or removing a voter is a one-line edit, and the voting set is kept
# narrow and co-located so a WAN link flap can't cost you quorum.
#
# This is a generalised, self-contained NixOS module. Drop it into your config
# and import it. No external topology file is required -- the topology lives in
# the `peers` option below.
#
# Usage (identical module on every voter, differing only in which host it runs
# on -- `nodeName` defaults to the hostname):
#
#   imports = [ ./etcd-cluster-over-tailnet ];
#
#   services.etcdMesh = {
#     enable = true;
#     interface = "tailscale0";          # your private mesh interface
#     clusterToken = "my-etcd-cluster";  # shared by all members
#     peers = {                          # the *voting* set only
#       node-a = "100.100.0.1";
#       node-b = "100.100.0.2";
#       node-c = "100.100.0.3";
#     };
#   };
#
# The `peers` attrset is the whole cluster topology: keys are etcd member
# names, values are the address each member is reachable at *on the private
# interface*. Keep this set small (3 or 5) and inside one low-latency zone.
# Machines that consume the cluster but must never vote (e.g. cross-WAN
# read replicas) simply are NOT listed here.

{
  config,
  lib,
  ...
}:

let
  cfg = config.services.etcdMesh;

  # This node's private-interface address. Normally looked up from the topology
  # (`peers`), but a node that is JOINING an already-running cluster with
  # `initialClusterState = "existing"` is registered out-of-band via
  # `etcdctl member add` and is deliberately NOT part of the static bootstrap
  # `peers` set -- such a node advertises its address via `nodeAddress`.
  nodeAddress = if cfg.nodeAddress != null then cfg.nodeAddress else cfg.peers.${cfg.nodeName};

  # initial-cluster string, e.g. "node-a=http://10.0.0.1:2380,node-b=..."
  # Derived from the single `peers` attrset so topology lives in exactly one
  # place. Every member computes the *same* list.
  initialCluster = lib.mapAttrsToList (
    name: addr: "${name}=http://${addr}:${toString cfg.peerPort}"
  ) cfg.peers;
in
{
  options.services.etcdMesh = {
    enable = lib.mkEnableOption "etcd cluster node bound to a private mesh interface";

    nodeName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = ''
        This member's etcd name. Must be a key of `peers`. Defaults to the
        machine's hostname.
      '';
    };

    peers = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      example = {
        node-a = "100.100.0.1";
        node-b = "100.100.0.2";
        node-c = "100.100.0.3";
      };
      description = ''
        The etcd voting set: member name -> address reachable on the private
        mesh interface. This IS the cluster topology; keep it small (3/5) and
        co-located in one low-latency zone so a WAN partition to any other
        machine cannot break quorum. Nodes that consume etcd but must never
        vote are deliberately omitted.
      '';
    };

    nodeAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "100.100.0.9";
      description = ''
        This node's address on the private mesh interface. Leave null to look it
        up from `peers` (the normal case for a bootstrap voter). Set it
        explicitly only for a node that runs etcd and advertises itself but is
        NOT in the static bootstrap `peers` set -- i.e. a member being added to an
        already-running cluster with `initialClusterState = "existing"` after an
        out-of-band `etcdctl member add`.
      '';
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "tailscale0";
      example = "wg0";
      description = ''
        Private mesh interface name. etcd's client and peer ports are opened
        ONLY on this interface -- never on the public firewall.
      '';
    };

    clientPort = lib.mkOption {
      type = lib.types.port;
      default = 2379;
      description = "etcd client API port.";
    };

    peerPort = lib.mkOption {
      type = lib.types.port;
      default = 2380;
      description = "etcd peer (raft) port.";
    };

    clusterToken = lib.mkOption {
      type = lib.types.str;
      default = "etcd-cluster";
      description = ''
        Shared initial-cluster-token. Every member must use the same value;
        it namespaces the cluster so a stray peer from another cluster can't
        accidentally join. Not a secret in the cryptographic sense, but keep
        it distinct per cluster.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/etcd";
      example = "/persist/etcd";
      description = ''
        Raft log + data directory. If you run an impermanence / wiped-root
        setup, point this at a persistent path (and persist it) so the raft
        log survives a reboot -- losing it makes the node re-bootstrap and can
        break the cluster.
      '';
    };

    autoCompactionRetention = lib.mkOption {
      type = lib.types.str;
      default = "1h";
      example = "24h";
      description = ''
        etcd `--auto-compaction-retention`. etcd keeps every historical
        revision until something compacts it, and it does NOT compact on its
        own unless this is set.

        Leaving it unset is a slow-motion outage. A Patroni cluster rewrites
        its leader key every `loop_wait` seconds, so revisions accumulate
        indefinitely for a keyspace that never grows: one observed cluster
        held 9 live keys in a 441 MB backend, having never compacted since it
        was created. Two things eventually break. The backend crosses
        `--quota-backend-bytes` (2 GiB by default) and etcd goes
        **read-only**, which takes the DCS and therefore every dependent
        cluster down. And long before that, a member joining or rejoining has
        to receive the whole bloated backend as a snapshot, turning a
        sub-second join into a multi-minute one.

        Set to "0" to disable, if you compact from outside.
      '';
    };

    startTimeoutSec = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = ''
        systemd `TimeoutStartSec` for the etcd unit.

        systemd's 90 s default (or a distro's shorter one) is measured against
        the wrong thing: a member joining an existing cluster must receive and
        load a full snapshot of the backend before it reports ready, and that
        is a function of the backend's size, not of how healthy the node is.
        A start timeout shorter than that transfer kills etcd mid-load, over
        and over, and the resulting log looks like a membership problem rather
        than a timeout. Keep this comfortably above the worst-case snapshot
        load for your backend size.
      '';
    };

    initialClusterState = lib.mkOption {
      type = lib.types.enum [
        "new"
        "existing"
      ];
      default = "new";
      description = ''
        etcd initial-cluster-state -- the one operational knob.

        Leave "new" for the initial bring-up of all voters at once.

        Flip to "existing" when adding a voter to an already-running cluster,
        and ONLY after you have registered the new peer on the existing members
        with `etcdctl member add <name> --peer-urls=http://<addr>:<peerPort>`.
        Starting a fresh node with "new" against a live cluster, or with
        "existing" before the member-add, makes etcd refuse to join.

        `member add --learner` is the safe way to grow a small cluster,
        because a learner does not count toward quorum and so cannot cost you
        quorum while it catches up. It carries one trap that is easy to walk
        into: **a learner answers connections but rejects most RPCs**, and
        clients do not necessarily skip it. Patroni's etcd3 client in
        particular will select a learner from its host list and then fail
        every watch with
        `watchprefix failed: rpc not supported for learner`, losing its view
        of the DCS -- where the previous, fully-down node had simply been
        skipped as unreachable. Either keep the joining node out of client
        host lists until it is promoted, or promote it as soon as its
        RaftAppliedIndex matches the leader's. Do not leave a learner sitting
        in a client's endpoint list.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.peers ? ${cfg.nodeName}) || (cfg.nodeAddress != null);
        message = "services.etcdMesh: nodeName \"${cfg.nodeName}\" is not a key of `peers` and no explicit `nodeAddress` was set.";
      }
    ];

    services.etcd = {
      enable = true;
      name = cfg.nodeName;
      inherit (cfg) dataDir;

      # Bind the client API to the mesh address AND loopback, so local
      # `etcdctl` works without going over the network.
      listenClientUrls = [
        "http://${nodeAddress}:${toString cfg.clientPort}"
        "http://127.0.0.1:${toString cfg.clientPort}"
      ];
      # Peer (raft) traffic is mesh-only -- never advertise a public address.
      listenPeerUrls = [
        "http://${nodeAddress}:${toString cfg.peerPort}"
      ];
      advertiseClientUrls = [
        "http://${nodeAddress}:${toString cfg.clientPort}"
      ];
      initialAdvertisePeerUrls = [
        "http://${nodeAddress}:${toString cfg.peerPort}"
      ];

      inherit initialCluster;
      initialClusterToken = cfg.clusterToken;
      inherit (cfg) initialClusterState;

      extraConf.AUTO_COMPACTION_RETENTION = cfg.autoCompactionRetention;
    };

    systemd.services.etcd.serviceConfig.TimeoutStartSec = cfg.startTimeoutSec;

    # Open the etcd ports ONLY on the private mesh interface. Because these
    # are per-interface rules, the ports stay closed on every public NIC even
    # if the global firewall is otherwise permissive.
    networking.firewall.interfaces.${cfg.interface}.allowedTCPPorts = [
      cfg.clientPort
      cfg.peerPort
    ];
  };
}
