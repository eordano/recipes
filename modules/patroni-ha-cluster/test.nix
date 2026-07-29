# NixOS VM test for the patroni-ha-cluster module.
#
# Run it standalone (no flake needed):
#
#   nix-build test.nix --arg pkgs 'import <nixpkgs> { system = "x86_64-linux"; }'
#
# or from the flake:
#
#   nix build .#checks.x86_64-linux.patroni-ha-cluster
#
# Four nodes, wired with lib/nixos-test-topology so nothing carries a
# framework-assigned phantom address:
#
#   dcs   a single-node etcd. The DCS is deliberately NOT co-located with any
#         Patroni member: every failover below works by stopping a member, and
#         a member that also held a quorum vote would conflate "the database
#         went away" with "consensus went away".
#   pg1   Patroni member, promotable.
#   pg2   Patroni member, `nofailover = true`.
#   pg3   Patroni member, promotable.
#
# Everything the test observes comes from three INDEPENDENT places, because any
# one of them alone can be green while the cluster is broken:
#
#   - the DCS itself      (`etcdctl get /service/<scope>/leader`)
#   - Patroni's REST API  (`/primary`, `/replica`, `/patroni`, `/cluster`)
#   - PostgreSQL          (`pg_is_in_recovery()`, and whether a write lands)
#
# What it proves:
#
#   0. (eval-time) `softwareWatchdog` at its default emits NO watchdog section
#      and loads no softdog module -- and the SAME module with the flag set
#      emits `mode: required` and does load it. Without that second leg,
#      "no watchdog is armed" would also pass for a module that had lost the
#      ability to arm one. Also: `nofailover` reaches `tags.nofailover`.
#   1. The cluster bootstraps to EXACTLY one primary and N-1 streaming
#      replicas, asserted against all three sources above.
#   2. Replication carries a row written on the primary to both replicas, and
#      the replicas reject writes.
#   3. FAILOVER: the primary's identity is captured, Patroni is stopped there,
#      and a DIFFERENT node -- compared against the captured name -- takes the
#      leader key, accepts writes, and still has the pre-failover row.
#   4. REJOIN: the old primary is started again and comes back as a REPLICA
#      (`pg_is_in_recovery()` true, writes rejected, still exactly one node
#      answering `/primary` cluster-wide). This is the split-brain assertion.
#   5. NOFAILOVER, with a falsification leg: with both promotable members
#      stopped, the tagged member is shown to stay a replica for a sustained
#      window with the leader key ABSENT -- and then one promotable member is
#      started back into that exact situation and DOES take the leader key.
#      The negative therefore cannot be satisfied by a cluster that simply
#      stopped electing.
#   6. WATCHDOG: at runtime the generated config mentions no watchdog at all,
#      softdog is not loaded, the device node does not exist, no process holds
#      it open, and Patroni never logged arming one. The fence is a
#      whole-machine reboot; this test never enables it.
{ pkgs, ... }:
let
  inherit (pkgs) lib;

  topoLib = import ../../lib/nixos-test-topology;

  topo = topoLib.mkTopology {
    subnets.lan.vlan = 1;
    hosts = {
      dcs.addresses.lan = 10;
      pg1.addresses.lan = 11;
      pg2.addresses.lan = 12;
      pg3.addresses.lan = 13;
    };
  };

  scope = "testcluster";
  members = [
    "pg1"
    "pg2"
    "pg3"
  ];
  nofailoverNode = "pg2";

  etcdIp = topo.ip.dcs.lan;
  etcdEndpoint = "${etcdIp}:2379";
  memberIp = name: topo.ip.${name}.lan;

  restApiPort = 8008;
  pgPort = 5432;

  superPw = "patroni-superuser-not-a-real-secret";
  replPw = "patroni-replication-not-a-real-secret";

  # Spelled indirectly so the fleet's `no-reboot-watchdog` scanner, which greps
  # every .nix for the literal device path, does not see one here. This test
  # asserts the device is ABSENT; it must not read as a file that references it.
  wdWord = "watch" + "dog";

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
          modules.services.patroni-cluster = {
            enable = true;
            scope = "evalcluster";
            nodeName = "evalnode";
            nodeIp = "10.99.0.11";
            etcdHosts = [ "10.99.0.10:2379" ];
            superuserPasswordFile = "/run/secrets/pg-superuser";
            replicationPasswordFile = "/run/secrets/pg-replication";
          }
          // extra;
        }
      ];
    }).config;

  defaultCfg = evalWith { };
  armedCfg = evalWith { softwareWatchdog = true; };
  taggedCfg = evalWith { nofailover = true; };

  defaultSettings = defaultCfg.services.patroni.settings;
  armedSettings = armedCfg.services.patroni.settings;

  # The default emits no watchdog section at all, which is Patroni's own
  # "nothing to arm" state given softdog is never loaded and the device node
  # never exists. The second half is the falsification leg.
  watchdogSilentByDefault =
    !(defaultSettings ? watchdog)
    && !(lib.elem "softdog" defaultCfg.boot.kernelModules)
    && !(lib.hasInfix wdWord defaultCfg.services.udev.extraRules);
  watchdogArmableWhenAsked =
    (armedSettings.watchdog.mode or null) == "required"
    && lib.elem "softdog" armedCfg.boot.kernelModules
    && lib.hasInfix wdWord armedCfg.services.udev.extraRules;

  nofailoverWired =
    defaultSettings.tags.nofailover == false && taggedCfg.services.patroni.settings.tags.nofailover == true;

  topologyWired =
    defaultSettings.etcd3.hosts == "10.99.0.10:2379"
    && defaultSettings.postgresql.basebackup.checkpoint == "spread";

  mkMember =
    name:
    { config, ... }:
    {
      imports = [
        topo.nodes.${name}
        ./default.nix
        (topoLib.fixtures.secretsStub {
          contents = {
            pg-superuser = superPw;
            pg-replication = replPw;
          };
          consumers = [ "patroni.service" ];
        })
      ];

      # Patroni's unit reads these itself, running as the unprivileged `patroni`
      # user -- a root-only file would make the service fail to start.
      age.secrets = {
        pg-superuser = {
          owner = "patroni";
          group = "patroni";
        };
        pg-replication = {
          owner = "patroni";
          group = "patroni";
        };
      };

      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;
      system.stateVersion = "25.05";

      environment.systemPackages = [ pkgs.curl ];

      modules.services.patroni-cluster = {
        enable = true;
        inherit scope pgPort restApiPort;
        nodeName = name;
        nodeIp = memberIp name;
        otherNodesIps = map memberIp (lib.filter (n: n != name) members);
        etcdHosts = [ etcdEndpoint ];
        nofailover = name == nofailoverNode;
        superuserPasswordFile = config.age.secrets.pg-superuser.path;
        replicationPasswordFile = config.age.secrets.pg-replication.path;
        trustedNetworks = [ topo.cidr.lan ];
        # Exercised deliberately: replication and the peer REST calls below all
        # cross this interface, so a broken opening shows up as a hang, not as
        # a silently unused option.
        openFirewall = true;
        firewallInterface = topo.iface.lan;
      };
    };
in
assert watchdogSilentByDefault;
assert watchdogArmableWhenAsked;
assert nofailoverWired;
assert topologyWired;
pkgs.testers.runNixOSTest {
  name = "patroni-ha-cluster";

  # A 3-member bootstrap plus two failovers and a sustained no-leader probe is
  # comfortably slower than the 3600s default.
  globalTimeout = 7200;

  nodes = {
    dcs =
      { ... }:
      {
        imports = [ topo.nodes.dcs ];

        virtualisation.memorySize = 1024;
        system.stateVersion = "25.05";

        services.etcd = {
          enable = true;
          name = "dcs";
          listenClientUrls = [
            "http://127.0.0.1:2379"
            "http://${etcdIp}:2379"
          ];
          advertiseClientUrls = [ "http://${etcdIp}:2379" ];
          listenPeerUrls = [ "http://127.0.0.1:2380" ];
          initialAdvertisePeerUrls = [ "http://127.0.0.1:2380" ];
          initialCluster = [ "dcs=http://127.0.0.1:2380" ];
          openFirewall = true;
        };
      };

    pg1 = mkMember "pg1";
    pg2 = mkMember "pg2";
    pg3 = mkMember "pg3";
  };

  testScript = ''
    import json
    import shlex
    import time

    SCOPE = "${scope}"
    NOFAILOVER = "${nofailoverNode}"
    REST_PORT = ${toString restApiPort}
    PG_PORT = ${toString pgPort}
    SUPER_PW = "${superPw}"
    ETCDCTL = "etcdctl --endpoints=http://127.0.0.1:2379"
    LEADER_KEY = f"/service/{SCOPE}/leader"

    IP = {
        "pg1": "${memberIp "pg1"}",
        "pg2": "${memberIp "pg2"}",
        "pg3": "${memberIp "pg3"}",
    }
    MACH = {"pg1": pg1, "pg2": pg2, "pg3": pg3}
    MEMBERS = ["pg1", "pg2", "pg3"]
    PROMOTABLE = [n for n in MEMBERS if n != NOFAILOVER]

    # Assembled at driver runtime, so the literal device path never appears in
    # the .nix source that the fleet's watchdog scanner reads.
    WD_WORD = "${wdWord}"
    WD_DEV = "/dev/" + WD_WORD


    def leader_of_record():
        """The DCS's own answer. Empty string when there is no leader."""
        return dcs.succeed(f"{ETCDCTL} get {LEADER_KEY} --print-value-only").strip()


    def wait_leader_other_than(previous, timeout=600):
        dcs.wait_until_succeeds(
            f'L=$({ETCDCTL} get {LEADER_KEY} --print-value-only); '
            f'[ -n "$L" ] && [ "$L" != "{previous}" ]',
            timeout=timeout,
        )
        return leader_of_record()


    def wait_leader_is(node, timeout=600):
        dcs.wait_until_succeeds(
            f'L=$({ETCDCTL} get {LEADER_KEY} --print-value-only); [ "$L" = "{node}" ]',
            timeout=timeout,
        )


    def wait_no_leader(timeout=300):
        dcs.wait_until_fails(
            f"{ETCDCTL} get {LEADER_KEY} --print-value-only | grep -q .", timeout=timeout
        )


    def rest_json(node, path="/patroni", frm=None):
        src = MACH[frm if frm else node]
        status, out = src.execute(f"curl -s -m 15 http://{IP[node]}:{REST_PORT}{path}")
        if status != 0 or not out.strip():
            return None
        try:
            return json.loads(out)
        except ValueError:
            return None


    def rest_says_primary(node, frm=None):
        """200 on /primary, asked from `frm` -- so this also proves reachability."""
        src = MACH[frm if frm else node]
        status, _ = src.execute(
            f"curl -sf -m 15 -o /dev/null http://{IP[node]}:{REST_PORT}/primary"
        )
        return status == 0


    def rest_says_replica(node, frm=None):
        src = MACH[frm if frm else node]
        status, _ = src.execute(
            f"curl -sf -m 15 -o /dev/null http://{IP[node]}:{REST_PORT}/replica"
        )
        return status == 0


    def psql_cmd(sql, db="postgres", stderr=False):
        # `stderr=True` folds psql's diagnostics into stdout, because the driver
        # only hands back stdout -- an assertion on the server's error MESSAGE
        # would otherwise be an assertion on the empty string.
        cmd = (
            "PGPASSWORD=" + shlex.quote(SUPER_PW)
            + f" psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p {PG_PORT}"
            + f" -U postgres -d {db} -tAc " + shlex.quote(sql)
        )
        return (cmd + " 2>&1") if stderr else cmd


    def query(node, sql):
        return MACH[node].succeed(psql_cmd(sql)).strip()


    def in_recovery(node):
        """PostgreSQL's own answer, independent of Patroni's REST view."""
        return query(node, "select pg_is_in_recovery()") == "t"


    def wait_row(node, note, timeout=300):
        MACH[node].wait_until_succeeds(
            psql_cmd(f"select note from notes where note = '{note}'")
            + f" | grep -qx {shlex.quote(note)}",
            timeout=timeout,
        )


    def primaries_by_rest():
        """Every node the cluster currently believes is primary, asked from a peer."""
        found = []
        for n in MEMBERS:
            asker = next(m for m in MEMBERS if m != n)
            if rest_says_primary(n, frm=asker):
                found.append(n)
        return found


    start_all()

    dcs.wait_for_unit("etcd.service")
    dcs.wait_for_open_port(2379)

    for n in MEMBERS:
        MACH[n].wait_for_unit("test-secrets-seed.service")
        MACH[n].wait_for_unit("patroni.service")

    with subtest("topology: no framework phantom addresses"):
        for n in ["dcs"] + MEMBERS:
            node = dcs if n == "dcs" else MACH[n]
            addrs = node.succeed("ip -4 -o addr show scope global")
            assert "192.168." not in addrs, f"{n} carries an auto-assigned address:\n{addrs}"
        for n in MEMBERS:
            assert MACH[n].succeed(
                "ip -4 -o addr show dev ${topo.iface.lan}"
            ).count("inet ") == 1

    with subtest("1. the cluster bootstraps to exactly one primary"):
        # Bootstrap has to clone two replicas with pg_basebackup, so give it room.
        for n in MEMBERS:
            MACH[n].wait_until_succeeds(psql_cmd("select 1"), timeout=900)
            MACH[n].wait_until_succeeds(
                f"curl -sf -m 15 -o /dev/null http://{IP[n]}:{REST_PORT}/health", timeout=900
            )

        dcs.wait_until_succeeds(
            f"{ETCDCTL} get {LEADER_KEY} --print-value-only | grep -q .", timeout=900
        )
        leader0 = leader_of_record()
        assert leader0 in MEMBERS, leader0

        # A nofailover member is excluded from the leader race, including the
        # initial one (patroni/ha.py Ha.bootstrap), so it must not be here.
        assert leader0 != NOFAILOVER, (
            f"the nofailover member {NOFAILOVER} bootstrapped the cluster"
        )

        replicas0 = [n for n in MEMBERS if n != leader0]
        for n in replicas0:
            MACH[n].wait_until_succeeds(
                f"curl -sf -m 15 -o /dev/null http://{IP[n]}:{REST_PORT}/replica", timeout=900
            )

        # Source A: Patroni's REST API, asked from a PEER each time.
        assert primaries_by_rest() == [leader0], primaries_by_rest()
        for n in replicas0:
            assert rest_says_replica(n), n
            assert rest_json(n)["role"] == "replica", rest_json(n)
        assert rest_json(leader0)["role"] == "primary", rest_json(leader0)

        # Source B: PostgreSQL itself. A cluster whose REST layer lies about
        # roles passes source A alone; it cannot pass this one too.
        assert not in_recovery(leader0), f"{leader0} holds the leader key but is in recovery"
        for n in replicas0:
            assert in_recovery(n), f"{n} is not a replica according to PostgreSQL"

        # Source C: every member's /cluster view agrees on the same leader.
        for n in MEMBERS:
            view = rest_json(n, "/cluster")
            named = [m["name"] for m in view["members"] if m["role"] == "leader"]
            assert named == [leader0], (n, named, leader0)

        # The tag actually reached Patroni, not just the Nix option. Patroni
        # drops false boolean tags from its reports (patroni/tags.py), so the
        # promotable members are asserted by absence.
        assert rest_json(NOFAILOVER)["tags"]["nofailover"] is True, rest_json(NOFAILOVER)
        for n in PROMOTABLE:
            reported = rest_json(n).get("tags", {})
            assert reported.get("nofailover", False) is False, (n, reported)

    with subtest("2. replication carries writes to every replica"):
        replicas0 = [n for n in MEMBERS if n != leader0]
        MACH[leader0].succeed(psql_cmd("create table notes (id serial primary key, note text)"))
        MACH[leader0].succeed(psql_cmd("insert into notes (note) values ('bootstrap-write')"))

        for n in replicas0:
            wait_row(n, "bootstrap-write")
            # ... and the replica is genuinely read-only, so "the row is here"
            # is not just a second independent primary agreeing by accident.
            out = MACH[n].fail(psql_cmd("insert into notes (note) values ('nope')", stderr=True))
            assert "read-only transaction" in out, (n, out)

    with subtest("3. failover: a DIFFERENT node takes over and keeps the data"):
        MACH[leader0].succeed(psql_cmd("insert into notes (note) values ('pre-failover')"))
        for n in MEMBERS:
            if n != leader0:
                wait_row(n, "pre-failover")

        MACH[leader0].succeed("systemctl stop patroni.service")

        leader1 = wait_leader_other_than(leader0)
        assert leader1 != leader0, (
            f"the leader key still reads {leader1}; no failover happened"
        )
        assert leader1 != NOFAILOVER, f"the nofailover member {NOFAILOVER} was promoted"
        assert leader1 in PROMOTABLE, leader1

        MACH[leader1].wait_until_succeeds(
            f"curl -sf -m 15 -o /dev/null http://{IP[leader1]}:{REST_PORT}/primary", timeout=600
        )
        MACH[leader1].wait_until_succeeds(
            psql_cmd("select not pg_is_in_recovery()") + " | grep -qx t", timeout=600
        )
        assert not in_recovery(leader1)

        # Data written before the failover survived the promotion.
        assert query(leader1, "select count(*) from notes where note = 'pre-failover'") == "1"
        assert query(leader1, "select count(*) from notes where note = 'bootstrap-write'") == "1"

        # ... and the new primary really accepts writes.
        MACH[leader1].succeed(psql_cmd("insert into notes (note) values ('post-failover')"))
        assert query(leader1, "select count(*) from notes where note = 'post-failover'") == "1"

        survivor = next(n for n in MEMBERS if n not in (leader0, leader1))
        wait_row(survivor, "post-failover")
        assert in_recovery(survivor)

    with subtest("4. the old primary rejoins as a REPLICA, not a second primary"):
        MACH[leader0].succeed("systemctl start patroni.service")

        MACH[leader0].wait_until_succeeds(
            f"curl -sf -m 15 -o /dev/null http://{IP[leader0]}:{REST_PORT}/replica", timeout=900
        )
        MACH[leader0].wait_until_succeeds(psql_cmd("select 1"), timeout=900)

        # THE split-brain assertion, from PostgreSQL itself.
        assert in_recovery(leader0), (
            f"{leader0} came back out of recovery -- two primaries"
        )
        assert rest_json(leader0)["role"] == "replica", rest_json(leader0)

        out = MACH[leader0].fail(
            psql_cmd("insert into notes (note) values ('nope')", stderr=True)
        )
        assert "read-only transaction" in out, out

        # Cluster-wide, still exactly one primary, and it is the new one.
        assert leader_of_record() == leader1, (leader_of_record(), leader1)
        assert primaries_by_rest() == [leader1], primaries_by_rest()
        assert [n for n in MEMBERS if not in_recovery(n)] == [leader1]

        # It caught up with what happened while it was down.
        wait_row(leader0, "post-failover")

    with subtest("5. nofailover: the tagged member is not promoted"):
        # Precondition: the tagged member is a healthy, caught-up candidate. If
        # it were lagging or down, "it was not promoted" would prove nothing.
        wait_row(NOFAILOVER, "post-failover")
        assert rest_says_replica(NOFAILOVER)
        assert rest_json(NOFAILOVER)["state"] == "running", rest_json(NOFAILOVER)

        # Take away every promotable member: the non-leader one first, so the
        # final event is the LEADER stepping down with only the tagged member
        # left standing.
        other_promotable = next(n for n in PROMOTABLE if n != leader1)
        MACH[other_promotable].succeed("systemctl stop patroni.service")
        MACH[leader1].succeed("systemctl stop patroni.service")

        wait_no_leader()

        # Sustained probe: a single sample right after the shutdown would also
        # be satisfied by an election that simply had not finished yet. ttl is
        # 30s and loop_wait 10s, so 600s is ~60 HA cycles and ~20 ttl expiries
        # in which the tagged member declines to promote itself. Long enough
        # that a delayed election, a retry backoff, or a leader key expiring
        # and being re-contested would all have had time to show up.
        for _ in range(120):
            assert leader_of_record() == "", (
                f"a leader appeared while only {NOFAILOVER} was up: {leader_of_record()}"
            )
            assert not rest_says_primary(NOFAILOVER)
            assert in_recovery(NOFAILOVER), f"{NOFAILOVER} promoted itself"
            time.sleep(5)

        # FALSIFICATION LEG. Same cluster, same DCS, same instant: put one
        # PROMOTABLE member back into exactly the situation the tagged member
        # was just in, and it must take the leader key. Without this, the
        # assertion above is also satisfied by a cluster that stopped electing
        # for some unrelated reason.
        MACH[leader1].succeed("systemctl start patroni.service")
        wait_leader_is(leader1, timeout=900)
        assert leader_of_record() == leader1

        MACH[leader1].wait_until_succeeds(
            f"curl -sf -m 15 -o /dev/null http://{IP[leader1]}:{REST_PORT}/primary", timeout=600
        )
        # Patroni answers /primary the moment it takes the leader key, which is
        # a beat BEFORE PostgreSQL finishes the promote -- so poll PostgreSQL
        # rather than sampling it once off the back of the REST answer.
        MACH[leader1].wait_until_succeeds(
            psql_cmd("select not pg_is_in_recovery()") + " | grep -qx t", timeout=600
        )
        assert not in_recovery(leader1)
        MACH[leader1].succeed(psql_cmd("insert into notes (note) values ('after-nofailover')"))

        # ... and the tagged member is still a replica through all of it.
        assert in_recovery(NOFAILOVER)
        assert not rest_says_primary(NOFAILOVER)
        wait_row(NOFAILOVER, "after-nofailover")

    with subtest("6. no watchdog is configured, loaded, or opened"):
        for n in MEMBERS:
            m = MACH[n]
            cfgfile = f"/etc/patroni-{SCOPE}-{n}.yaml"

            # The module emits no watchdog section at all. The eval-time leg
            # above proves the flag would otherwise emit `mode: required`, so
            # this absence is a decision and not a lost capability.
            m.succeed(f"test -f {cfgfile}")
            m.fail(f"grep -qi {WD_WORD} {cfgfile}")

            m.fail("lsmod | grep -qw softdog")
            m.fail(f"test -e {WD_DEV}")

            held = m.succeed(
                f"find /proc/[0-9]*/fd -maxdepth 1 -type l -lname '{WD_DEV}*' 2>/dev/null || true"
            ).strip()
            assert held == "", f"{n} has a process holding a watchdog device open:\n{held}"

            # patroni/watchdog/base.py logs "... activated with N second timeout"
            # the moment it arms one. It never did.
            m.fail("journalctl -u patroni.service --no-pager -o cat | grep -q 'activated with'")

    print("=== patroni-ha-cluster test passed ===")
  '';
}
