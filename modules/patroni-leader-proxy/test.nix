# NixOS VM test for the patroni-leader-proxy module.
#
# Run it standalone (no flake needed):
#
#   nix-build test.nix --arg pkgs 'import <nixpkgs> { system = "x86_64-linux"; }'
#
# or from the flake: `nix build .#checks.x86_64-linux.patroni-leader-proxy`.
#
# WHAT IS FAKED, AND WHY. The module's entire job is "route the client to
# whichever node currently answers `GET /primary` with 200". A real Patroni
# cluster contributes nothing to that question except latency and flakiness: to
# exercise a failover you would have to provoke a real leader election and then
# wait for it. So the backends here are ~60 lines of Python that mimic the two
# things HAProxy actually observes about a Patroni member:
#
#   * a REST API on `restApiPort` where `/primary` returns 200 only when this
#     node's role file says "primary", and `/replica` returns 200 only when it
#     says "replica" -- the same 200/503 contract the module health-checks;
#   * a TCP listener on `pgPort` standing in for PostgreSQL, which answers every
#     accepted connection with its OWN NODE NAME and counts how many connections
#     it has served.
#
# Flipping leadership is then `echo primary > /run/fakepatroni/role` -- instant,
# deterministic, and repeatable in both directions.
#
# HOW ROUTING IS MEASURED. Never from the proxy's own view of the world. Each
# proxied connection is identified two independent ways, both at the BACKEND:
#
#   1. the banner the client reads back is written by the backend that accepted
#      the connection, and
#   2. that backend's own connection counter (read over its REST port, not
#      through the proxy) is asserted to have moved by exactly one while every
#      other backend's counter is asserted not to have moved at all.
#
# "The proxy is listening" and "the proxy answered" are deliberately never
# accepted as evidence of where a connection went.
#
# THE ASSERTION THAT MATTERS is `NO LEADER`: with every backend reporting 503 on
# /primary, the proxy must refuse the connection rather than quietly hand a
# write session to a replica. That subtest is paired with a falsification leg --
# promote one node, re-run the identical command, require it to succeed and to
# land on the promoted node -- because a proxy that is simply broken and refuses
# everything would otherwise pass it.
{ pkgs, ... }:
let
  inherit (pkgs) lib;

  topology = import ../../lib/nixos-test-topology;

  # Two subnets, and every host's address declared explicitly, so no assertion
  # below can be undone by the framework's alphabetical-rank address scheme.
  # `mgmt` exists purely so `bindAddresses` has an address it must NOT bind:
  # a bind test on a single-homed host cannot distinguish "bound where I asked"
  # from "bound everywhere".
  #
  # Interface names are outside the kernel's own `ethN` namespace on purpose.
  # The multi-homed nodes carry a vlan-1 and a vlan-2 leg; leaving the default
  # `eth<vlan>` names in place makes udev rename eth1 -> eth1/eth2 in an order
  # that can collide, and the loser boots with a leg silently unconfigured.
  topo = topology.mkTopology {
    subnets = {
      db = {
        vlan = 1;
        interface = "db0";
      };
      mgmt = {
        vlan = 2;
        interface = "mgmt0";
      };
    };
    hosts = {
      client = {
        addresses = {
          db = 10;
          mgmt = 10;
        };
        primary = "db";
      };
      proxy = {
        addresses = {
          db = 20;
          mgmt = 20;
        };
        primary = "db";
      };
      roproxy.addresses.db = 21;
      pgone.addresses.db = 31;
      pgtwo.addresses.db = 32;
      pgthree.addresses.db = 33;
    };
  };

  s = builtins.toString;

  pgPort = 5432;
  restApiPort = 8008;
  rwPort = 15432;
  roPort = 15433;
  roleFile = "/run/fakepatroni/role";

  backends = [
    "pgone"
    "pgtwo"
    "pgthree"
  ];
  nodeAddresses = lib.genAttrs backends (n: topo.ip.${n}.db);

  # A stand-in Patroni member. The REST half implements the 200/503 role
  # contract the module health-checks; the TCP half stands in for PostgreSQL and
  # is what makes "which backend served this connection" answerable at all.
  #
  # The PG half reads before it writes. The client always speaks first, so the
  # exchange is a strict request/response: a server that answered and closed
  # while unread bytes were still inbound would RST the connection, and an RST
  # discards data already sitting in the peer's receive buffer -- i.e. the
  # banner could vanish on a socket that had in fact been routed correctly.
  fakePatroniPy = pkgs.writeText "fake-patroni.py" ''
    import http.server
    import socketserver
    import sys
    import threading

    NAME = sys.argv[1]
    PG_PORT = int(sys.argv[2])
    API_PORT = int(sys.argv[3])
    ROLE_FILE = sys.argv[4]

    state = {"conns": 0}
    lock = threading.Lock()


    def role():
        try:
            with open(ROLE_FILE) as fh:
                return fh.read().strip()
        except OSError:
            return "unknown"


    class Api(http.server.BaseHTTPRequestHandler):
        def reply(self, code, body):
            raw = body.encode()
            self.send_response(code)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(raw)
            self.close_connection = True

        def do_GET(self):
            path = self.path.split("?")[0]
            current = role()
            if path == "/connections":
                with lock:
                    served = state["conns"]
                self.reply(200, str(served))
            elif path in ("/primary", "/master", "/read-write"):
                self.reply(200 if current == "primary" else 503, NAME + " " + current)
            elif path in ("/replica", "/read-only"):
                self.reply(200 if current == "replica" else 503, NAME + " " + current)
            elif path == "/":
                self.reply(200, NAME + " " + current)
            else:
                self.reply(404, "unknown path")

        def log_message(self, *args):
            pass


    class Pg(socketserver.BaseRequestHandler):
        def handle(self):
            with lock:
                state["conns"] += 1
            self.request.settimeout(5)
            try:
                self.request.recv(64)
            except OSError:
                pass
            try:
                self.request.sendall((NAME + "\n").encode())
            except OSError:
                pass


    class Pool(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True


    pg = Pool(("0.0.0.0", PG_PORT), Pg)
    threading.Thread(target=pg.serve_forever, daemon=True).start()

    api = http.server.ThreadingHTTPServer(("0.0.0.0", API_PORT), Api)
    api.serve_forever()
  '';

  # Connect through the proxy and report which backend answered. Exits non-zero
  # both when the connection is refused outright and when it is accepted and
  # then closed with nothing behind it -- which is how HAProxy in TCP mode
  # rejects a session whose pool holds no live server.
  pgpingPy = pkgs.writeText "pgping.py" ''
    import socket
    import sys

    host = sys.argv[1]
    port = int(sys.argv[2])

    try:
        sock = socket.create_connection((host, port), timeout=8)
    except OSError as exc:
        sys.stderr.write("connect refused: " + str(exc) + "\n")
        sys.exit(1)

    sock.settimeout(8)
    try:
        sock.sendall(b"PING\n")
    except OSError:
        pass

    data = b""
    try:
        while not data:
            chunk = sock.recv(64)
            if not chunk:
                break
            data += chunk
    except OSError as exc:
        sys.stderr.write("read failed: " + str(exc) + "\n")
        sys.exit(1)
    sock.close()

    if not data:
        sys.stderr.write("accepted then closed with no backend behind it\n")
        sys.exit(1)

    sys.stdout.write(data.decode().strip() + "\n")
  '';

  pgping = pkgs.writeShellScriptBin "pgping" ''
    exec ${pkgs.python3}/bin/python3 ${pgpingPy} "$@"
  '';

  # `pgstable HOST PORT WANT [N]` -- N consecutive connections must ALL land on
  # WANT. A single probe hitting the right backend proves nothing while the
  # other backends are still in the pool: HAProxy considers a checked server UP
  # until `fall` checks have failed, so right after a role flip a round-robin
  # pool still contains stale members and one lucky probe would look like a
  # completed failover.
  pgstable = pkgs.writeShellScriptBin "pgstable" ''
    host=$1
    port=$2
    want=$3
    n=''${4:-5}
    i=0
    while [ "$i" -lt "$n" ]; do
      got=$(${pgping}/bin/pgping "$host" "$port") || exit 1
      if [ "$got" != "$want" ]; then
        echo "probe $i landed on '$got', wanted '$want'" >&2
        exit 1
      fi
      i=$((i + 1))
    done
    echo "$want"
  '';

  # `pgnot HOST PORT UNWANTED [N]` -- the settling gate for the read pool: N
  # consecutive connections must all succeed and none may land on UNWANTED.
  pgnot = pkgs.writeShellScriptBin "pgnot" ''
    host=$1
    port=$2
    unwanted=$3
    n=''${4:-6}
    i=0
    while [ "$i" -lt "$n" ]; do
      got=$(${pgping}/bin/pgping "$host" "$port") || exit 1
      if [ "$got" = "$unwanted" ]; then
        echo "probe $i landed on '$got', which must not be in this pool" >&2
        exit 1
      fi
      i=$((i + 1))
    done
    echo ok
  '';

  probeTools = [
    pgping
    pgstable
    pgnot
  ];

  fakePatroni =
    { name, initialRole }:
    { pkgs, ... }:
    {
      systemd.tmpfiles.settings."10-fakepatroni" = {
        "/run/fakepatroni".d = {
          mode = "0755";
          user = "root";
          group = "root";
        };
        ${roleFile}.f = {
          mode = "0644";
          user = "root";
          group = "root";
          argument = initialRole;
        };
      };

      systemd.services.fake-patroni = {
        description = "Stand-in Patroni member: REST role API + a TCP listener on the PG port";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network.target"
          "systemd-tmpfiles-setup.service"
        ];
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${fakePatroniPy} ${name} ${s pgPort} ${s restApiPort} ${roleFile}";
          Restart = "on-failure";
        };
      };

      environment.systemPackages = [
        pkgs.curl
        (pkgs.writeShellScriptBin "setrole" ''
          printf '%s' "$1" > ${roleFile}
        '')
      ];

      networking.firewall.enable = false;
      system.stateVersion = "25.05";
    };

  # The module under test, tuned for a VM: `inter 1s fall 2 rise 1` makes a
  # role flip observable in ~2s instead of the WAN-safe 25s the defaults buy.
  # The defaults themselves are asserted at eval time below, so shortening them
  # here cannot hide a regression in them.
  proxyNode =
    {
      selfAddress,
      readPort ? null,
    }:
    {
      imports = [ ./default.nix ];

      networking.firewall.enable = false;
      system.stateVersion = "25.05";
      environment.systemPackages = probeTools ++ [ pkgs.iproute2 ];

      services.patroni-leader-proxy = {
        enable = true;
        nodes = nodeAddresses;
        inherit pgPort restApiPort readPort;
        port = rwPort;
        bindAddresses = [
          "127.0.0.1"
          selfAddress
        ];
        checkInter = "1s";
        checkTimeout = "2s";
        checkFall = 2;
        checkRise = 1;
      };
    };

  # ---- eval-time: the tuning options must reach the generated backend config --
  #
  # Timing options are asserted here rather than in the VM on purpose: proving
  # `fall 7` by measuring how long a pool takes to drain is a race against the
  # test host's load, and a test that sleeps is a test that flakes. What the
  # module owes its user is that the numbers land in the config; HAProxy owns
  # what it does with them.
  evalHaproxyConfig =
    settings:
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
          services.patroni-leader-proxy = settings;
        }
      ];
    }).config.services.haproxy.config;

  tunedCfg = evalHaproxyConfig {
    enable = true;
    nodes = {
      alpha = "10.9.0.11";
      beta = "10.9.0.12";
    };
    pgPort = 6543;
    restApiPort = 7008;
    port = 16432;
    readPort = 16433;
    bindAddresses = [
      "127.0.0.1"
      "10.9.0.1"
    ];
    checkInter = "11s";
    checkTimeout = "13s";
    checkFall = 7;
    checkRise = 3;
  };

  defaultCfg = evalHaproxyConfig {
    enable = true;
    nodes.alpha = "10.9.0.11";
  };

  occurrences = needle: hay: (builtins.length (lib.splitString needle hay)) - 1;

  # Every tuned value is checked BOTH for presence and for the absence of the
  # default it replaced, so an option silently stopping at the module boundary
  # (hardcoded value, dropped interpolation) cannot pass.
  cfgChecks = [
    {
      ok = occurrences "default-server init-state down inter 11s fall 7 rise 3" tunedCfg == 2;
      msg = "checkInter/checkFall/checkRise are not in BOTH pools' default-server line";
    }
    {
      ok = !(lib.hasInfix "fall 5 rise 2" tunedCfg);
      msg = "the tuned config still carries the DEFAULT fall/rise -- the options are not wired through";
    }
    {
      ok = occurrences "timeout check 13s" tunedCfg == 2;
      msg = "checkTimeout is not in both pools";
    }
    {
      ok = occurrences "server alpha 10.9.0.11:6543 check port 7008" tunedCfg == 2;
      msg = "pgPort/restApiPort are not both reflected in the server lines of both pools";
    }
    {
      ok = occurrences "server beta 10.9.0.12:6543 check port 7008" tunedCfg == 2;
      msg = "the second node is missing from a pool";
    }
    {
      ok = lib.hasInfix "bind 127.0.0.1:16432" tunedCfg && lib.hasInfix "bind 10.9.0.1:16432" tunedCfg;
      msg = "every bindAddress must get a bind line on the read-write port";
    }
    {
      ok = lib.hasInfix "bind 127.0.0.1:16433" tunedCfg && lib.hasInfix "bind 10.9.0.1:16433" tunedCfg;
      msg = "every bindAddress must get a bind line on readPort";
    }
    {
      ok = lib.hasInfix "http-check send meth GET uri /primary" tunedCfg;
      msg = "the read-write pool no longer health-checks Patroni's /primary";
    }
    {
      ok = lib.hasInfix "http-check send meth GET uri /replica" tunedCfg;
      msg = "the read pool no longer health-checks Patroni's /replica";
    }
    {
      ok = occurrences "http-check expect status 200" tunedCfg == 2;
      msg = "a pool no longer requires 200 from the role endpoint";
    }
    {
      ok = lib.hasInfix "default-server init-state down inter 5s fall 5 rise 2" defaultCfg;
      msg = "the documented WAN-tolerant defaults (inter 5s fall 5 rise 2) changed";
    }
    {
      # HAProxy's own default is to hold a checked server UP until a check
      # fails, which would put every node in the RW pool for checkInter *
      # checkFall after start and round-robin a write onto a replica.
      ok = occurrences "init-state down" defaultCfg == occurrences "default-server" defaultCfg;
      msg = "a pool's default-server lost `init-state down`; the RW pool would accept writes on replicas for the first checkInter*checkFall after HAProxy starts";
    }
    {
      ok = lib.hasInfix "timeout check 8s" defaultCfg;
      msg = "the documented default checkTimeout (8s) changed";
    }
    {
      ok = !(lib.hasInfix "listen patroni-ro" defaultCfg);
      msg = "readPort is unset, yet a read pool was generated";
    }
    {
      ok = lib.hasInfix "listen patroni-ro" tunedCfg;
      msg = "readPort is set, yet no read pool was generated";
    }
    {
      ok = lib.hasInfix "balance roundrobin" tunedCfg;
      msg = "the read pool no longer round-robins";
    }
  ];

  failedCfgChecks = lib.filter (c: !c.ok) cfgChecks;
in
assert lib.assertMsg (failedCfgChecks == [ ]) ''
  patroni-leader-proxy: the generated HAProxy config no longer matches what this
  test asserts. Failing checks:
  ${lib.concatMapStringsSep "\n" (c: "  - " + c.msg) failedCfgChecks}

  Generated config with every option tuned away from its default:
  ${tunedCfg}

  Generated config with defaults:
  ${defaultCfg}
'';
pkgs.testers.runNixOSTest {
  name = "patroni-leader-proxy";

  nodes = {
    pgone = {
      imports = [
        topo.nodes.pgone
        (fakePatroni {
          name = "pgone";
          initialRole = "primary";
        })
      ];
    };

    pgtwo = {
      imports = [
        topo.nodes.pgtwo
        (fakePatroni {
          name = "pgtwo";
          initialRole = "replica";
        })
      ];
    };

    pgthree = {
      imports = [
        topo.nodes.pgthree
        (fakePatroni {
          name = "pgthree";
          initialRole = "replica";
        })
      ];
    };

    # The default shape: read-write pool only, no readPort.
    proxy = {
      imports = [
        topo.nodes.proxy
        (proxyNode { selfAddress = topo.ip.proxy.db; })
      ];
    };

    # The same module with the optional replica pool switched on. A second host
    # rather than a second port on `proxy`, so that "readPort is absent when
    # unset" can be asserted on a live system and not only at eval time.
    roproxy = {
      imports = [
        topo.nodes.roproxy
        (proxyNode {
          selfAddress = topo.ip.roproxy.db;
          readPort = roPort;
        })
      ];
    };

    client = {
      imports = [ topo.nodes.client ];
      networking.firewall.enable = false;
      system.stateVersion = "25.05";
      environment.systemPackages = probeTools;
    };
  };

  testScript = ''
    PROXY = "${topo.ip.proxy.db}"
    PROXY_MGMT = "${topo.ip.proxy.mgmt}"
    ROPROXY = "${topo.ip.roproxy.db}"
    RW = ${s rwPort}
    RO = ${s roPort}

    BACKENDS = {"pgone": pgone, "pgtwo": pgtwo, "pgthree": pgthree}


    def ping(host, port):
        return f"pgping {host} {port}"


    def stable(host, port, want, n=5):
        return f"pgstable {host} {port} {want} {n}"


    def avoids(host, port, unwanted, n=6):
        return f"pgnot {host} {port} {unwanted} {n}"


    def set_roles(**roles):
        for name, role in roles.items():
            BACKENDS[name].succeed(f"setrole {role}")


    def conns():
        """Connections each backend has served, read from the backend itself."""
        return {
            name: int(m.succeed("curl -sf http://127.0.0.1:${s restApiPort}/connections").strip())
            for name, m in BACKENDS.items()
        }


    def delta(before, after):
        return {name: after[name] - before[name] for name in before}


    def served_by(host, port, expected):
        """One connection, cross-checked at the backend that took it."""
        before = conns()
        got = client.succeed(ping(host, port)).strip()
        moved = delta(before, conns())
        assert got == expected, f"banner said {got!r}, expected {expected!r}"
        assert moved[expected] == 1, (
            f"{expected} returned the banner but its own connection counter did not "
            f"move: {moved}"
        )
        for name, n in moved.items():
            if name != expected:
                assert n == 0, f"{name} also took a connection: {moved}"
        return got


    start_all()

    for m in BACKENDS.values():
        m.wait_for_unit("fake-patroni.service")
        m.wait_for_open_port(${s restApiPort})
        m.wait_for_open_port(${s pgPort})
    proxy.wait_for_unit("haproxy.service")
    roproxy.wait_for_unit("haproxy.service")
    client.wait_for_unit("multi-user.target")

    with subtest("no phantom framework addresses anywhere"):
        for m, name in (
            (client, "client"),
            (proxy, "proxy"),
            (roproxy, "roproxy"),
            (pgone, "pgone"),
            (pgtwo, "pgtwo"),
            (pgthree, "pgthree"),
        ):
            addrs = m.succeed("ip -4 -o addr show scope global")
            assert "192.168." not in addrs, (
                f"{name} carries a framework auto-assigned address:\n{addrs}"
            )

    with subtest("the fake members answer Patroni's role contract"):
        # If /primary answered 200 everywhere, every routing claim below would be
        # satisfied by a proxy that ignored the health check entirely.
        set_roles(pgone="primary", pgtwo="replica", pgthree="replica")
        for m in BACKENDS.values():
            m.succeed("curl -sf -o /dev/null http://127.0.0.1:${s restApiPort}/")
        pgone.succeed("curl -sf -o /dev/null http://127.0.0.1:${s restApiPort}/primary")
        pgone.fail("curl -sf -o /dev/null http://127.0.0.1:${s restApiPort}/replica")
        pgtwo.fail("curl -sf -o /dev/null http://127.0.0.1:${s restApiPort}/primary")
        pgtwo.succeed("curl -sf -o /dev/null http://127.0.0.1:${s restApiPort}/replica")

    with subtest("the proxy listens on the configured addresses and ports, and nowhere else"):
        proxy.wait_for_open_port(RW, addr="127.0.0.1")
        proxy.wait_for_open_port(RW, addr=PROXY)

        # The negative half is only meaningful if the address it names exists.
        onhost = proxy.succeed("ip -4 -o addr show scope global")
        assert PROXY_MGMT in onhost, (
            f"the proxy does not hold {PROXY_MGMT}, so 'it did not bind there' is "
            f"vacuous:\n{onhost}"
        )

        listeners = proxy.succeed("ss -lnt")
        assert f"127.0.0.1:{RW}" in listeners, listeners
        assert f"{PROXY}:{RW}" in listeners, listeners
        assert f"{PROXY_MGMT}:{RW}" not in listeners, (
            f"the proxy bound an address that is not in bindAddresses:\n{listeners}"
        )
        assert f"0.0.0.0:{RW}" not in listeners and f"*:{RW}" not in listeners, (
            f"the proxy bound the wildcard address instead of bindAddresses:\n{listeners}"
        )

        # readPort is unset on this node: no second pool may exist.
        assert f":{RO}" not in listeners, (
            f"readPort is unset, yet something is listening on {RO}:\n{listeners}"
        )
        assert "listen patroni-ro" not in proxy.succeed("cat /etc/haproxy.cfg")

        # And from off-host: reachable on the bound leg, refused on the other.
        client.wait_until_succeeds(ping(PROXY, RW), timeout=90)
        client.fail(ping(PROXY_MGMT, RW))
        client.fail(ping(PROXY, RO))

    with subtest("connections land on the node that claims to be leader"):
        set_roles(pgone="primary", pgtwo="replica", pgthree="replica")
        # HAProxy holds a checked server UP until `fall` checks have failed, so
        # after start the pool briefly contains all three. Wait for it to settle
        # on the leader alone before measuring.
        client.wait_until_succeeds(stable(PROXY, RW, "pgone"), timeout=90)
        served_by(PROXY, RW, "pgone")
        # The loopback bind carries traffic too, not merely a socket.
        assert proxy.succeed(ping("127.0.0.1", RW)).strip() == "pgone"

    with subtest("FAILOVER FOLLOW: new connections go to the newly promoted node"):
        before_leader = client.succeed(ping(PROXY, RW)).strip()
        set_roles(pgone="replica", pgtwo="primary")
        client.wait_until_succeeds(stable(PROXY, RW, "pgtwo"), timeout=90)
        after_leader = client.succeed(ping(PROXY, RW)).strip()

        assert before_leader == "pgone", before_leader
        assert after_leader == "pgtwo", after_leader
        assert before_leader != after_leader, (
            f"the proxy served {after_leader} both before and after the failover -- "
            "it did not follow the leader"
        )
        # Same claim, made at the backends rather than from the banner.
        served_by(PROXY, RW, "pgtwo")

    with subtest("NO LEADER: the proxy refuses instead of routing a write to a replica"):
        set_roles(pgone="replica", pgtwo="replica", pgthree="replica")
        client.wait_until_fails(ping(PROXY, RW), timeout=90)

        before = conns()
        for _ in range(5):
            client.fail(ping(PROXY, RW))
        moved = delta(before, conns())
        assert all(n == 0 for n in moved.values()), (
            "with no node claiming leadership the proxy still delivered connections "
            f"to a replica: {moved}. This is the failure mode the recipe exists to "
            "prevent -- a write session handed to a read-only node."
        )
        # The refusal is the pool's doing, not a dead listener.
        proxy.succeed("systemctl is-active haproxy.service")
        assert f"{PROXY}:{RW}" in proxy.succeed("ss -lnt")

        # FALSIFICATION LEG. A proxy that refuses everything would have passed
        # every assertion above. Promote one node and require the very same
        # command to succeed, and to land on the node just promoted.
        set_roles(pgthree="primary")
        client.wait_until_succeeds(stable(PROXY, RW, "pgthree"), timeout=90)
        served_by(PROXY, RW, "pgthree")

    with subtest("readPort routes to replicas and never to the leader"):
        set_roles(pgone="primary", pgtwo="replica", pgthree="replica")

        roproxy.wait_for_open_port(RO, addr="127.0.0.1")
        roproxy.wait_for_open_port(RO, addr=ROPROXY)
        ro_listeners = roproxy.succeed("ss -lnt")
        assert f"127.0.0.1:{RO}" in ro_listeners, ro_listeners
        assert f"{ROPROXY}:{RO}" in ro_listeners, ro_listeners

        # The read-write port of the SAME proxy still tracks the leader, which is
        # what makes "the read pool avoided pgone" a statement about pool
        # membership rather than about pgone being unreachable.
        client.wait_until_succeeds(stable(ROPROXY, RW, "pgone"), timeout=90)
        client.wait_until_succeeds(avoids(ROPROXY, RO, "pgone"), timeout=90)

        before = conns()
        seen = [client.succeed(ping(ROPROXY, RO)).strip() for _ in range(12)]
        moved = delta(before, conns())

        assert "pgone" not in seen, (
            f"the leader served a connection on readPort: {seen}. Reads were routed "
            "to the primary."
        )
        assert moved["pgone"] == 0, (
            f"the leader's own connection counter moved during read-pool traffic: {moved}"
        )
        assert set(seen) == {"pgtwo", "pgthree"}, (
            f"readPort did not round-robin across the live replicas: {seen}"
        )
        assert moved["pgtwo"] > 0 and moved["pgthree"] > 0, (
            f"only one replica actually served read connections: {moved}"
        )
        assert moved["pgtwo"] + moved["pgthree"] == 12, moved

    print("=== patroni-leader-proxy: leader routing, failover follow, "
          "no-leader refusal and replica pool verified at the backends ===")
  '';
}
