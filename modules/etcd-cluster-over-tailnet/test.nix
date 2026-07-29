# NixOS VM test for the etcd-cluster-over-tailnet module.
#
# Run it standalone (no flake needed):
#
#   nix-build test.nix --arg pkgs 'import <nixpkgs> { system = "x86_64-linux"; }'
#
# or from a flake:
#
#   pkgs.callPackage ./modules/etcd-cluster-over-tailnet/test.nix { }
#
# Three voters on ONE private subnet, wired with lib/nixos-test-topology so no
# node carries a framework auto-assigned address. (`virtualisation.vlans = [ N ]`
# would hand out a SECOND address per interface, because
# `networking.interfaces.<i>.ipv4.addresses` is a list option and definitions
# MERGE; mkForce would only hide that, not fix it.)
#
#             mesh 10.1.0/24
#   alpha .11 ── bravo .12 ── charlie .13
#
# Every node imports the module with an IDENTICAL `services.etcdMesh` block --
# `nodeName` defaults to the hostname, which is the module's documented usage.
# The mesh interface stands in for tailscale0/wg0: the module opens the client
# and peer ports ONLY there, and the global firewall stays ON. So the cluster
# forming at all is already a functional test of the per-interface firewall
# opening -- had the module opened nothing, raft could never connect.
#
# Non-default ports (12379/12380) are used deliberately: a module that ignored
# `clientPort`/`peerPort` and baked in etcd's defaults would fail here instead
# of passing by coincidence.
#
# FAULT INJECTION. Stopping etcd is done with KillSignal=SIGKILL, so `systemctl
# stop` is an abrupt kill and NOT a graceful shutdown. This matters: etcd
# transfers leadership on SIGTERM, so a graceful stop would hand the term to a
# successor and "a new leader exists" would be true without a raft election ever
# having run. The drop-in is asserted live before anything relies on it.
#
# What it proves, and what breaking it would look like:
#
#   0. (eval-time) URLs, the initial-cluster string, the token and the
#      per-interface firewall openings are all derived from `peers` + the port
#      options; the ports are NOT in the global `allowedTCPPorts`; the
#      nodeName/nodeAddress assertion fires for an unlisted member and is
#      satisfied by an explicit `nodeAddress` (the documented
#      `initialClusterState = "existing"` join case).
#   1. The cluster forms: all three healthy, ONE leader all three agree on,
#      identical cluster id and identical member list everywhere.
#   2. A write on ANY member is readable on EVERY member -- and out of every
#      member's OWN store, not merely proxied to the leader on read.
#   3. LEADER LOSS. The leader's identity is captured BEFORE the kill and the
#      new leader is asserted to be a DIFFERENT member; "a leader exists" is
#      satisfied for free by a leader that never stepped down. Writes still
#      succeed on the two survivors. The old leader is then restarted and must
#      rejoin as a FOLLOWER (its status names the new leader, not itself) and
#      CATCH UP: a key written while it was down is read back from its own local
#      store with a serializable read, and its revision reaches the leader's.
#      "It is healthy again" would prove neither of those.
#   4. QUORUM LOSS -- the data-safety assertion. With 2 of 3 down the survivor
#      must REFUSE to serve. Proven as a triad, not as "the cluster reports
#      unhealthy":
#        * the write FAILS, and
#        * the linearizable read FAILS, while
#        * the SERIALIZABLE read of the same key still returns the pre-outage
#          value -- so the server is demonstrably alive and holding the data,
#          and the two failures are a deliberate refusal rather than a dead
#          process. A stale read served as current would surface right here.
#        * the local revision does not advance, so the refused write left no
#          trace at all.
#   5. QUORUM RESTORED -- the falsification leg for every negative in 4. The
#      byte-identical put that failed during the outage now SUCCEEDS, so the
#      refusal was about quorum and not about a malformed command. Before that
#      write lands, the pre-outage value is asserted intact on both the survivor
#      and the node that was down -- i.e. the refused write committed nowhere.
#      Finally the third member returns and all three converge.
{ pkgs, ... }:
let
  inherit (pkgs) lib;

  topoLib = import ../../lib/nixos-test-topology;

  nodeNames = [
    "alpha"
    "bravo"
    "charlie"
  ];

  topo = topoLib.mkTopology {
    subnets.mesh.vlan = 1;
    hosts = lib.listToAttrs (
      lib.imap0 (i: n: lib.nameValuePair n { addresses.mesh = 11 + i; }) nodeNames
    );
  };

  clientPort = 12379;
  peerPort = 12380;
  cp = toString clientPort;
  pp = toString peerPort;

  clusterToken = "vmtest-etcd-mesh";

  peers = lib.listToAttrs (map (n: lib.nameValuePair n topo.ip.${n}.mesh) nodeNames);

  # The configuration under test. Defined once so the eval-time checks and the
  # VM nodes cannot drift apart, and identical on every voter -- which is the
  # module's headline usage claim.
  etcdMeshConfig = {
    enable = true;
    interface = topo.iface.mesh;
    inherit
      clientPort
      peerPort
      clusterToken
      peers
      ;
  };

  # --- 0. eval-time checks ---------------------------------------------------
  evalWith =
    extra:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        ./default.nix
        {
          boot.loader.grub.enable = false;
          system.stateVersion = "25.05";
          fileSystems."/" = {
            device = "/dev/vda";
            fsType = "ext4";
          };
          networking.hostName = "alpha";
          services.etcdMesh = etcdMeshConfig;
        }
        extra
      ];
    }).config;

  goodEval = evalWith { };
  failing = cfg: builtins.filter (x: !x.assertion) cfg.assertions;

  goodOk = failing goodEval == [ ];

  selfAddr = topo.ip.alpha.mesh;

  # Every etcd URL is derived from `peers` + the port options -- one topology,
  # five URL sets. A hardcoded port or a dropped loopback URL fails here.
  urlsOk =
    let
      e = goodEval.services.etcd;
    in
    e.enable
    && e.name == "alpha"
    && e.listenClientUrls == [
      "http://${selfAddr}:${cp}"
      "http://127.0.0.1:${cp}"
    ]
    && e.listenPeerUrls == [ "http://${selfAddr}:${pp}" ]
    && e.advertiseClientUrls == [ "http://${selfAddr}:${cp}" ]
    && e.initialAdvertisePeerUrls == [ "http://${selfAddr}:${pp}" ]
    && e.initialCluster == map (n: "${n}=http://${topo.ip.${n}.mesh}:${pp}") nodeNames
    && e.initialClusterToken == clusterToken
    && e.initialClusterState == "new";

  # Mesh-only: the ports are opened on the mesh interface and are NOT in the
  # global list, so they stay shut on every public NIC.
  firewallOk =
    let
      f = goodEval.networking.firewall;
    in
    f.interfaces.${topo.iface.mesh}.allowedTCPPorts == [
      clientPort
      peerPort
    ]
    && !(lib.elem clientPort f.allowedTCPPorts)
    && !(lib.elem peerPort f.allowedTCPPorts)
    && !goodEval.services.etcd.openFirewall;

  # A member that is neither a key of `peers` nor given a `nodeAddress` has no
  # address to advertise. That must surface as the module's own assertion.
  strayOk = builtins.any (
    x: lib.hasInfix "is not a key of" x.message && lib.hasInfix "delta" x.message
  ) (failing (evalWith { networking.hostName = lib.mkForce "delta"; }));

  # The documented join case: absent from the bootstrap `peers` set, address
  # given explicitly, cluster state "existing".
  joiningEval = evalWith {
    networking.hostName = lib.mkForce "delta";
    services.etcdMesh = {
      nodeAddress = "10.1.0.14";
      initialClusterState = "existing";
    };
  };
  joinOk =
    failing joiningEval == [ ]
    && joiningEval.services.etcd.listenPeerUrls == [ "http://10.1.0.14:${pp}" ]
    && joiningEval.services.etcd.advertiseClientUrls == [ "http://10.1.0.14:${cp}" ]
    && joiningEval.services.etcd.initialClusterState == "existing"
    && !(lib.any (lib.hasPrefix "delta=") joiningEval.services.etcd.initialCluster);

  machinesDict = lib.concatMapStringsSep ", " (n: "${n}=${n}") nodeNames;
  meshDict = lib.concatMapStringsSep ", " (n: "${n}='${topo.ip.${n}.mesh}'") nodeNames;

  node =
    name:
    { config, ... }:
    let
      etcdctl = "${config.services.etcd.package}/bin/etcdctl";

      # Thin wrapper so the test script never repeats endpoint/timeout flags.
      # It targets 127.0.0.1 on purpose: the module adds a loopback client URL
      # so local etcdctl works without routing over the mesh, and every command
      # in this test exercises that.
      etcdc = pkgs.writeShellScriptBin "etcdc" ''
        exec ${etcdctl} \
          --endpoints=http://127.0.0.1:${cp} \
          --command-timeout=6s --dial-timeout=2s "$@"
      '';

      # Prints the CURRENT leader's member name, or exits non-zero when there is
      # no leader / the local server cannot answer. Written in python because
      # etcd member ids are uint64 and jq would silently mangle them through a
      # double, quietly turning every leader-identity assertion into a coin flip.
      etcdLeader = pkgs.writeScriptBin "etcd-leader" ''
        #!${pkgs.python3}/bin/python3
        import json
        import subprocess
        import sys

        FLAGS = [
            "--endpoints=http://127.0.0.1:${cp}",
            "--command-timeout=6s",
            "--dial-timeout=2s",
            "-w", "json",
        ]

        def ctl(*args):
            p = subprocess.run(["${etcdctl}", *FLAGS, *args],
                               capture_output=True, text=True)
            if p.returncode != 0:
                return None
            return json.loads(p.stdout)

        st = ctl("endpoint", "status")
        if st is None:
            sys.exit(2)
        leader = st[0]["Status"].get("leader", 0)
        if not leader:
            sys.exit(1)
        ml = ctl("member", "list")
        if ml is None:
            sys.exit(3)
        for m in ml.get("members", []):
            if m.get("ID") == leader:
                print(m.get("name", ""))
                sys.exit(0)
        sys.exit(4)
      '';
    in
    {
      imports = [
        ./default.nix
        topo.nodes.${name}
      ];

      system.stateVersion = "25.05";

      # Left ON deliberately. The module opens the etcd ports only on the mesh
      # interface, so a cluster that forms is proof those per-interface rules
      # exist and work.
      networking.firewall.enable = true;

      services.etcdMesh = etcdMeshConfig;

      # Fault injection, not tuning: an abrupt kill instead of etcd's graceful
      # shutdown, which transfers leadership and would rob the election subtest
      # of anything to observe.
      systemd.services.etcd.serviceConfig.KillSignal = "SIGKILL";

      environment.systemPackages = [
        etcdc
        etcdLeader
        pkgs.iptables
      ];
    };
in
assert lib.assertMsg goodOk "etcd-cluster-over-tailnet test: the deployed config has failing assertions: ${
  lib.generators.toPretty { } (failing goodEval)
}";
assert lib.assertMsg urlsOk "etcd-cluster-over-tailnet test: services.etcd URLs are no longer derived from `peers` + the port options: ${
  lib.generators.toPretty { } goodEval.services.etcd
}";
assert lib.assertMsg firewallOk "etcd-cluster-over-tailnet test: the etcd ports are no longer opened ONLY on the mesh interface. per-interface=${
  lib.generators.toPretty { } goodEval.networking.firewall.interfaces.${topo.iface.mesh}.allowedTCPPorts
} global=${lib.generators.toPretty { } goodEval.networking.firewall.allowedTCPPorts}";
assert lib.assertMsg strayOk
  "etcd-cluster-over-tailnet test: a nodeName that is not a key of `peers` and has no `nodeAddress` no longer trips the module's assertion";
assert lib.assertMsg joinOk "etcd-cluster-over-tailnet test: the `nodeAddress` + existing-cluster join case is broken: ${
  lib.generators.toPretty { } joiningEval.services.etcd
}";
pkgs.testers.runNixOSTest {
  name = "etcd-cluster-over-tailnet";

  nodes = lib.genAttrs nodeNames node;

  testScript = ''
    import json

    MACHINES = dict(${machinesDict})
    MESH = dict(${meshDict})
    ALL = list(MACHINES.values())

    KEY_SHARED = "app/shared"
    KEY_DOWN = "app/written-while-down"
    VAL_DOWN = "replicated-to-a-node-that-was-offline"
    KEY_SAFE = "app/safety"
    VAL_SAFE = "committed-with-quorum"
    VAL_OUTAGE = "written-without-quorum"

    # The one command the quorum subtests hinge on. It is run byte-identically
    # in subtest 4 (must fail) and subtest 5 (must succeed), so the negative can
    # never be an artefact of a mistyped command.
    OUTAGE_PUT = f"etcdc put {KEY_SAFE} {VAL_OUTAGE}"

    QUORUM_ERRORS = (
        "request timed out",
        "context deadline exceeded",
        "no leader",
        "leader changed",
    )


    def jctl(node, args):
        return json.loads(node.succeed(f"etcdc -w json {args}"))


    def status(node):
        return jctl(node, "endpoint status")[0]["Status"]


    def member_map(node):
        return {m["ID"]: m.get("name", "") for m in jctl(node, "member list")["members"]}


    def leader_of(node):
        return node.succeed("etcd-leader").strip()


    def value(node, key, local=False):
        flag = " --consistency=s" if local else ""
        return node.succeed(f"etcdc get{flag} {key} --print-value-only").strip()


    def revision(node, key, local=False):
        flag = " --consistency=s" if local else ""
        return jctl(node, f"get{flag} {key}")["header"].get("revision", 0)


    def local_value_is(key, val):
        return f'[ "$(etcdc get --consistency=s {key} --print-value-only)" = {val} ]'


    def crash(node):
        # KillSignal=SIGKILL makes this a crash, not a handover. `execute` and
        # not `succeed`: the unit may legitimately end up in a failed state, and
        # the evidence that matters is the probe below, not systemctl's exit code.
        node.execute("systemctl stop etcd.service")
        node.wait_until_fails("etcdc endpoint status", timeout=90)


    def revive(node):
        node.execute("systemctl reset-failed etcd.service")
        node.succeed("systemctl --no-block start etcd.service")
        node.wait_for_unit("etcd.service")


    start_all()

    for m in ALL:
        m.wait_for_unit("etcd.service")

    with subtest("topology: no phantom framework addresses, one address per leg"):
        for m in ALL:
            addrs = m.succeed("ip -4 -o addr show scope global")
            assert "192.168." not in addrs, (
                f"{m.name} carries a framework auto-assigned 192.168.* address:\n{addrs}"
            )
            assert addrs.count("inet ") == 1, (
                f"{m.name} has more than one global IPv4 address, so `peers` no longer "
                f"describes where this member actually is:\n{addrs}"
            )
            assert MESH[m.name] in addrs, (
                f"{m.name} does not carry its declared mesh address:\n{addrs}"
            )

    with subtest("etcd listens on the mesh address and loopback, and nowhere else"):
        for m in ALL:
            listening = m.succeed("ss -ltnH")
            mesh = MESH[m.name]
            for port in ("${cp}", "${pp}"):
                assert f"{mesh}:{port}" in listening, (
                    f"{m.name} is not listening on its mesh address for port {port}:\n"
                    f"{listening}"
                )
                assert f"0.0.0.0:{port}" not in listening, (
                    f"{m.name} listens on a wildcard address for port {port} -- peer or "
                    f"client traffic would be reachable off the mesh:\n{listening}"
                )
            # The loopback client URL the module adds on purpose; every etcdc
            # invocation in this test goes through it.
            assert "127.0.0.1:${cp}" in listening, listening
            # ... and no loopback PEER url: raft is mesh-only.
            assert "127.0.0.1:${pp}" not in listening, listening

    with subtest("the etcd ports are open only on the mesh interface"):
        for m in ALL:
            rules = m.succeed("iptables -S")
            port_rules = [
                r for r in rules.splitlines()
                if "dport ${cp}" in r or "dport ${pp}" in r
            ]
            assert port_rules, (
                f"{m.name} has no firewall rule for the etcd ports at all, yet the "
                f"cluster is expected to form through them:\n{rules}"
            )
            assert all("-i ${topo.iface.mesh}" in r for r in port_rules), (
                f"{m.name} opens an etcd port without scoping it to the mesh "
                "interface, so it is reachable from every NIC:\n" + "\n".join(port_rules)
            )

    with subtest("fault injection is armed: stopping etcd is a kill, not a handover"):
        # If this ever degrades to SIGTERM, etcd hands leadership to a successor
        # on shutdown and subtest 3 would observe a "new leader" without a single
        # raft election having taken place.
        for m in ALL:
            sig = m.succeed("systemctl show -p KillSignal --value etcd.service").strip()
            assert sig in ("SIGKILL", "9"), (
                f"{m.name} would receive {sig} on stop; the leader-loss subtest needs "
                "an abrupt kill or it proves nothing about re-election"
            )

    with subtest("1. the cluster forms: one leader, one member list, one cluster id"):
        for m in ALL:
            m.wait_until_succeeds("etcdc endpoint health", timeout=180)
            m.wait_until_succeeds("etcd-leader", timeout=180)

        expected = set(MACHINES)
        maps = {m.name: member_map(m) for m in ALL}
        for name, mm in maps.items():
            assert set(mm.values()) == expected, (
                f"{name} sees member set {sorted(mm.values())}, expected "
                f"{sorted(expected)}"
            )
        # Same ids for the same names on every member, not merely the same count.
        assert len({json.dumps(mm, sort_keys=True) for mm in maps.values()}) == 1, (
            f"the three members disagree about the member list: {maps}"
        )

        cluster_ids = {m.name: status(m)["header"]["cluster_id"] for m in ALL}
        assert len(set(cluster_ids.values())) == 1, (
            "the members are not in the same cluster -- clusterToken or the "
            f"initial-cluster string did not take: {cluster_ids}"
        )

        leaders = {m.name: leader_of(m) for m in ALL}
        assert len(set(leaders.values())) == 1, (
            f"the members disagree about who the leader is: {leaders}"
        )
        the_leader = leaders[ALL[0].name]
        assert the_leader in expected, leaders

        # Exactly ONE member reports ITSELF as leader. Reading the leader id off
        # each node separately is what makes "exactly one" a real count rather
        # than a restatement of the agreement check above.
        self_leading = [
            m.name for m in ALL
            if status(m).get("leader", 0) == status(m)["header"]["member_id"]
        ]
        assert self_leading == [the_leader], (
            f"expected exactly one self-reported leader ({the_leader}), got "
            f"{self_leading}"
        )

    with subtest("2. a write on any member is readable on every member"):
        for writer in ALL:
            val = f"written-by-{writer.name}"
            writer.succeed(f"etcdc put {KEY_SHARED} {val}")
            for reader in ALL:
                got = value(reader, KEY_SHARED)
                assert got == val, (
                    f"{writer.name} wrote {val!r} but {reader.name} reads {got!r}"
                )
                # ... and it really is in that member's own store, not merely
                # forwarded to the leader at read time.
                reader.wait_until_succeeds(local_value_is(KEY_SHARED, val), timeout=60)

    with subtest("3. LEADER LOSS: a DIFFERENT member is elected"):
        old_leader_name = leader_of(ALL[0])
        old_leader = MACHINES[old_leader_name]
        survivors = [m for m in ALL if m.name != old_leader_name]

        old_leader.succeed(f"etcdc put {KEY_SHARED} before-the-kill")

        crash(old_leader)

        # The identity check this subtest exists for: "a leader exists" is true
        # for free if the old one never stepped down.
        for m in survivors:
            m.wait_until_succeeds(
                f'[ -n "$(etcd-leader)" ] && [ "$(etcd-leader)" != {old_leader_name} ]',
                timeout=180,
            )

        new_leaders = {m.name: leader_of(m) for m in survivors}
        assert len(set(new_leaders.values())) == 1, (
            f"the survivors disagree about the new leader: {new_leaders}"
        )
        new_leader_name = new_leaders[survivors[0].name]
        assert new_leader_name != old_leader_name, (
            f"the leader did not change: still {old_leader_name}"
        )
        assert new_leader_name in [m.name for m in survivors], (
            f"the survivors report {new_leader_name} as leader, which is not among them"
        )

        with subtest("writes still succeed on the two survivors"):
            for m in survivors:
                val = f"post-election-by-{m.name}"
                m.wait_until_succeeds(f"etcdc put {KEY_SHARED} {val}", timeout=120)
                for r in survivors:
                    assert value(r, KEY_SHARED) == val, (
                        f"{m.name} wrote {val!r} but {r.name} does not read it back"
                    )
            # Written while the old leader is DOWN -- so it cannot possibly have
            # this key yet. The catch-up check below is built on that.
            survivors[0].succeed(f"etcdc put {KEY_DOWN} {VAL_DOWN}")
            leader_rev = revision(MACHINES[new_leader_name], KEY_DOWN)

        with subtest("the old leader rejoins as a FOLLOWER and catches up"):
            revive(old_leader)

            old_leader.wait_until_succeeds(
                f'[ "$(etcd-leader)" = {new_leader_name} ]', timeout=240
            )
            st = status(old_leader)
            assert st.get("leader", 0) != 0, st
            assert st.get("leader", 0) != st["header"]["member_id"], (
                f"{old_leader_name} came back as the leader, not as a follower: {st}"
            )

            # CATCH-UP, read out of its OWN store with a serializable read: no
            # forwarding to the leader can fake this one.
            old_leader.wait_until_succeeds(local_value_is(KEY_DOWN, VAL_DOWN), timeout=240)
            caught_up = revision(old_leader, KEY_DOWN, local=True)
            assert caught_up >= leader_rev, (
                f"{old_leader_name} serves the key from a local revision "
                f"{caught_up}, behind the revision {leader_rev} at which it was "
                "committed -- it has not actually caught up"
            )

    with subtest("4. QUORUM LOSS: the lone survivor REFUSES to serve"):
        leader_name = leader_of(ALL[0])
        # Keep a FOLLOWER alive: a member with a full local copy and no
        # authority is exactly where a stale read would come from.
        survivor = next(m for m in ALL if m.name != leader_name)
        doomed = [m for m in ALL if m.name != survivor.name]

        survivor.succeed(f"etcdc put {KEY_SAFE} {VAL_SAFE}")
        survivor.wait_until_succeeds(local_value_is(KEY_SAFE, VAL_SAFE), timeout=120)
        rev_before = revision(survivor, KEY_SAFE, local=True)

        for m in doomed:
            crash(m)

        # No leader anywhere: 1 of 3 cannot win an election.
        survivor.wait_until_fails("etcd-leader", timeout=240)

        with subtest("the write is REFUSED"):
            out = survivor.fail(f"{OUTAGE_PUT} 2>&1")
            assert any(s in out for s in QUORUM_ERRORS), (
                "the write failed, but not with a quorum/leader error -- this failure "
                f"may have nothing to do with quorum:\n{out}"
            )

        with subtest("the linearizable read is REFUSED too"):
            out = survivor.fail(f"etcdc get {KEY_SAFE} 2>&1")
            assert any(s in out for s in QUORUM_ERRORS), out

        with subtest("... while the server is alive and still holds the data"):
            # The control that turns the two failures above into "the survivor
            # refused" rather than "the survivor is dead". A serializable read is
            # served purely out of the local store, so it answers the question
            # "would a stale value have been available to hand out?" with yes --
            # and the linearizable read above still refused to hand it out.
            got = value(survivor, KEY_SAFE, local=True)
            assert got == VAL_SAFE, (
                f"the local store no longer holds the pre-outage value: {got!r}"
            )
            survivor.succeed("systemctl is-active --quiet etcd.service")

        with subtest("the refused write left no trace"):
            rev_after = revision(survivor, KEY_SAFE, local=True)
            assert rev_after == rev_before, (
                f"the local revision moved from {rev_before} to {rev_after} during an "
                "outage in which every write was supposed to have been refused"
            )
            assert value(survivor, KEY_SAFE, local=True) != VAL_OUTAGE

    with subtest("5. QUORUM RESTORED: the same write succeeds, old data intact"):
        returning = doomed[0]
        revive(returning)

        for m in (survivor, returning):
            m.wait_until_succeeds("etcd-leader", timeout=300)
            m.wait_until_succeeds("etcdc endpoint health", timeout=300)

        with subtest("the pre-outage value survived; the refused write never landed"):
            for m in (survivor, returning):
                got = value(m, KEY_SAFE)
                assert got == VAL_SAFE, (
                    f"{m.name} reads {got!r} for {KEY_SAFE}; the value committed BEFORE "
                    f"the outage was {VAL_SAFE!r}"
                )
            # Straight out of the local store of the node that was DOWN while
            # the refused write was attempted.
            assert value(returning, KEY_SAFE, local=True) == VAL_SAFE

        with subtest("FALSIFICATION: the byte-identical put succeeds with quorum back"):
            survivor.wait_until_succeeds(OUTAGE_PUT, timeout=180)
            for m in (survivor, returning):
                assert value(m, KEY_SAFE) == VAL_OUTAGE, (
                    f"{m.name} does not read back the write that just succeeded"
                )
            rev_now = revision(survivor, KEY_SAFE, local=True)
            assert rev_now > rev_before, (
                f"the successful write did not advance the revision ({rev_before} -> "
                f"{rev_now})"
            )

        with subtest("the third member returns and all three converge"):
            revive(doomed[1])
            for m in ALL:
                m.wait_until_succeeds("etcdc endpoint health", timeout=300)
                m.wait_until_succeeds(local_value_is(KEY_SAFE, VAL_OUTAGE), timeout=300)
            leaders = {m.name: leader_of(m) for m in ALL}
            assert len(set(leaders.values())) == 1, leaders
            for m in ALL:
                assert set(member_map(m).values()) == set(MACHINES), m.name

            final = "after-full-recovery"
            ALL[-1].succeed(f"etcdc put {KEY_SHARED} {final}")
            for m in ALL:
                m.wait_until_succeeds(local_value_is(KEY_SHARED, final), timeout=180)

    print("=== etcd-cluster-over-tailnet: formation, election, quorum safety verified ===")
  '';
}
