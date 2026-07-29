# NixOS VM test for the per-uid-egress-lockdown module.
#
# Run it standalone (no flake needed):
#
#   nix-build test.nix --arg pkgs 'import <nixpkgs> { system = "x86_64-linux"; }'
#
# or from a flake:
#
#   pkgs.callPackage ./modules/per-uid-egress-lockdown/test.nix { }
#
# ---------------------------------------------------------------------------
# What it proves, and why each assertion cannot be satisfied by accident
# ---------------------------------------------------------------------------
#
# The module makes one claim that matters: the squid ACL is ADVISORY and the
# nftables `output` rule is the enforcement. A test that only drives traffic
# through the proxy proves the advisory half and nothing else -- it would stay
# green with the whole nft table deleted.
#
# So every network assertion here is paired with a PACKET COUNTER, and the two
# counters sit on opposite sides of the boundary:
#
#   * an `output`-hook counter ON the confined host, at priority -300, matching
#     `meta skuid <confined uid>` -- i.e. BEFORE the module's chain (priority 0)
#     gets to drop anything. It answers "did the confined process actually emit
#     a packet at the destination?".
#   * a `forward`-hook counter on the ROUTER (lib/nixos-test-topology's
#     `fixtures.forwardCounter`). It answers "did that packet leave the box?".
#
# The bypass subtest asserts BOTH: output counter > 0 (the process really tried)
# AND router counter == 0 (nothing got out). A broken module fails one or the
# other -- a deleted nft table makes the router counter non-zero and the request
# succeed; a test topology that quietly stopped routing makes the output counter
# zero and would otherwise look like a successful "block".
#
#   0. (eval time) uid == proxyUid is rejected by the module's own assertion.
#      This is the module's documented corollary, and it is an EVAL-time
#      property: see the note at the bottom of this comment.
#   1. The confined uid reaches an allowlisted destination through the proxy,
#      the traffic transits the router, and the confined uid itself never sent
#      a packet at the destination (the proxy uid did).
#   2. The confined uid gets 403 for a non-allowlisted domain, and the router
#      sees zero packets toward it -- squid refused, rather than the network
#      being broken.
#   3. THE CENTRAL CLAIM. The confined uid connects DIRECTLY to the allowlisted
#      destination's IP with the proxy explicitly disabled. The kernel drops it
#      (EPERM), the local output counter proves the SYN was emitted, and the
#      router's forward counter proves nothing left the host.
#   4. A different uid on the same host runs the identical command against the
#      identical address and succeeds -- including to the NON-allowlisted
#      destination. The lockdown is scoped to the uid, not to the host.
#   5. The shipped bubblewrap launcher does all three of the above in one run
#      of the real wrapper, including `--noproxy '*'` from inside the sandbox.
#   6. The confined uid cannot resolve names either; DNS belongs to the proxy.
#
# On the "proxy must run as a different uid" corollary: the module asserts
# `uid != proxyUid` at eval, so subtest 0 is where that misconfiguration is
# caught, and it is caught before a VM ever boots. Would the RUNTIME test catch
# it if the assertion were removed? Yes, but only as collateral damage: with a
# shared uid the sandbox's `drop` rule matches squid's own egress, squid cannot
# reach any origin, and subtest 1 fails with a proxy-side error. That is a real
# failure but a misleading one -- it reads as "the proxy is broken", not as "the
# lockdown is void". The eval check is what names the actual fault.
{ pkgs, ... }:
let
  lib = pkgs.lib;
  topology = import ../../lib/nixos-test-topology;

  name = "confined";
  confinedUid = 60900;
  proxyUid = 60901;
  bystanderUid = 60950;
  proxyPort = 3128;
  proxyLog = "/run/${name}-squid/access.log";
  # Long enough for several SYN retransmits to hit the output hook, short
  # enough that two deliberate hangs do not dominate the test's runtime.
  bypassTimeout = 5;

  allowedBody = "ALLOWED-ORIGIN-PAYLOAD";
  deniedBody = "DENIED-ORIGIN-PAYLOAD";

  topo = topology.mkTopology {
    subnets = {
      lan.vlan = 1;
      ext.vlan = 2;
    };
    hosts = {
      # Alphabetical rank would have been agent=1, allowed=2, denied=3,
      # router=4 in 192.168.<vlan>.<rank>. mkTopology takes that away; the
      # first subtest asserts no 192.168.* address survives anywhere.
      agent = {
        addresses.lan = 10;
        via = "router";
      };
      allowed = {
        addresses.ext = 80;
        via = "router";
      };
      denied = {
        addresses.ext = 81;
        via = "router";
      };
      router = {
        addresses = {
          lan = 1;
          ext = 1;
        };
        forward = true;
      };
    };
  };

  allowedIP = topo.ip.allowed.ext;
  deniedIP = topo.ip.denied.ext;
  routerLanIP = topo.ip.router.lan;

  # One self-signed cert covering both origins. The clients use `-k`; the
  # subject of this test is the packet path, not PKI.
  originCert =
    pkgs.runCommand "per-uid-egress-lockdown-test-cert"
      {
        nativeBuildInputs = [ pkgs.openssl ];
      }
      ''
        mkdir -p $out
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
          -subj "/CN=allowed.test" \
          -addext "subjectAltName=DNS:allowed.test,DNS:denied.test,IP:${allowedIP},IP:${deniedIP}" \
          -keyout $out/key.pem -out $out/cert.pem 2>/dev/null
      '';

  originNode =
    { host, body }:
    { ... }:
    {
      imports = [ topo.nodes.${host} ];
      networking.firewall.enable = false;
      system.stateVersion = "25.05";
      services.nginx = {
        enable = true;
        virtualHosts."${host}.test" = {
          default = true;
          addSSL = true;
          sslCertificate = "${originCert}/cert.pem";
          sslCertificateKey = "${originCert}/key.pem";
          locations."/".return = "200 '${body}'";
        };
      };
    };

  # An `output`-hook counter on the confined host, at a priority BELOW the
  # module's chain, matching only the confined uid. This is the instrument that
  # distinguishes "the kernel dropped the packet" from "the program never sent
  # one" -- without it, a bypass subtest is satisfied by a typo in the URL.
  #
  # lib/nixos-test-topology's `fixtures.forwardCounter` is the same idea but is
  # hardwired to the `forward` hook, so it cannot be reused here; see the README
  # note about generalising it.
  outputCounterTable = "agent_out";
  outputCounterRules = pkgs.writeText "agent-out-counter.nft" ''
    table inet ${outputCounterTable} {}
    delete table inet ${outputCounterTable}
    table inet ${outputCounterTable} {
      counter confined_to_allowed { }
      counter confined_to_denied { }
      counter proxyuid_to_allowed { }
      chain output {
        type filter hook output priority -300; policy accept;
        meta skuid ${toString confinedUid} ip daddr ${allowedIP} tcp dport 443 counter name confined_to_allowed
        meta skuid ${toString confinedUid} ip daddr ${deniedIP} tcp dport 443 counter name confined_to_denied
        meta skuid ${toString proxyUid} ip daddr ${allowedIP} tcp dport 443 counter name proxyuid_to_allowed
      }
    }
  '';

  outCount = pkgs.writeShellScriptBin "outcount" ''
    exec ${pkgs.nftables}/bin/nft list counter inet ${outputCounterTable} "$1" \
      | ${pkgs.gawk}/bin/awk '$1 == "packets" { print $2; exit }'
  '';

  outReset = pkgs.writeShellScriptBin "outreset" ''
    for c in confined_to_allowed confined_to_denied proxyuid_to_allowed; do
      ${pkgs.nftables}/bin/nft reset counter inet ${outputCounterTable} "$c" >/dev/null
    done
  '';

  outputCounterModule = {
    environment.systemPackages = [
      outCount
      outReset
      pkgs.nftables
    ];
    systemd.services.agent-out-counter = {
      description = "output-hook per-uid packet counter (test instrument)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-pre.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.nftables}/bin/nft -f ${outputCounterRules}";
        ExecStop = "${pkgs.nftables}/bin/nft delete table inet ${outputCounterTable}";
      };
    };
  };

  # --- 0. eval-time: the "proxy must be a different uid" corollary ------------
  evalWith =
    mod:
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
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
        }
        mod
      ];
    };

  failedAssertions =
    e: map (a: a.message) (builtins.filter (a: !a.assertion) e.config.assertions);

  goodEval = evalWith {
    services.perUidEgressLockdown = {
      enable = true;
      inherit name;
      uid = confinedUid;
      inherit proxyUid;
      allowedDomains = [ "allowed.test" ];
      launcher.enable = false;
    };
  };

  sharedUidEval = evalWith {
    services.perUidEgressLockdown = {
      enable = true;
      inherit name;
      uid = confinedUid;
      proxyUid = confinedUid;
      allowedDomains = [ "allowed.test" ];
      launcher.enable = false;
    };
  };

  goodEvalClean = failedAssertions goodEval == [ ];
  sharedUidRejected = builtins.any (m: lib.hasInfix "must differ" m) (failedAssertions sharedUidEval);

  # The nft ruleset the module generates must actually name the confined uid and
  # end in a drop; checked here so a refactor that loses the rule fails at eval
  # rather than turning subtest 3 into a slow mystery.
  lockdownUnit = goodEval.config.systemd.services."${name}-egress-lockdown".serviceConfig.ExecStart;
  lockdownRules = builtins.readFile (lib.last (lib.splitString " " lockdownUnit));
  rulesDropConfinedUid = lib.hasInfix "meta skuid ${toString confinedUid} drop" lockdownRules;
in
assert goodEvalClean;
assert sharedUidRejected;
assert rulesDropConfinedUid;
pkgs.testers.runNixOSTest {
  name = "per-uid-egress-lockdown";

  nodes = {
    agent =
      { ... }:
      {
        imports = [
          ./default.nix
          topo.nodes.agent
          outputCounterModule
        ];

        system.stateVersion = "25.05";
        networking.firewall.enable = false;
        networking.nameservers = [ routerLanIP ];

        environment.systemPackages = [
          pkgs.curl
          pkgs.dnsutils
          pkgs.util-linux
        ];

        # An ordinary co-resident uid. Nothing about it is special; that is the
        # point of subtest 4.
        users.groups.bystander = { };
        users.users.bystander = {
          uid = bystanderUid;
          group = "bystander";
          isSystemUser = true;
        };

        services.perUidEgressLockdown = {
          enable = true;
          inherit name;
          uid = confinedUid;
          inherit proxyUid;
          allowedDomains = [ "allowed.test" ];
          proxy.port = proxyPort;

          launcher = {
            packages = [
              pkgs.curl
              pkgs.coreutils
            ];
            stateMounts."/state" = ".";
            # Three fetches in one real bubblewrap run: allowlisted via the
            # inherited HTTPS_PROXY, non-allowlisted via the same proxy, and a
            # deliberate proxy bypass by IP with --noproxy.
            command = ''
              curl -sS -f -k --max-time 20 https://allowed.test/ > /state/proxied-allowed.out 2> /state/proxied-allowed.err
              echo "exit=$?" >> /state/proxied-allowed.err
              curl -sS -f -k --max-time 20 https://denied.test/ > /state/proxied-denied.out 2> /state/proxied-denied.err
              echo "exit=$?" >> /state/proxied-denied.err
              curl -sS -f -k --max-time ${toString bypassTimeout} --noproxy '*' https://${allowedIP}/ > /state/bypass.out 2> /state/bypass.err
              echo "exit=$?" >> /state/bypass.err
            '';
          };
        };
      };

    allowed = originNode {
      host = "allowed";
      body = allowedBody;
    };

    denied = originNode {
      host = "denied";
      body = deniedBody;
    };

    router =
      { ... }:
      {
        imports = [
          topo.nodes.router
          (topology.fixtures.forwardCounter {
            name = "fwd_allow";
            match = "ip daddr ${allowedIP} tcp dport 443";
          })
          (topology.fixtures.forwardCounter {
            name = "fwd_deny";
            match = "ip daddr ${deniedIP} tcp dport 443";
          })
        ];
        system.stateVersion = "25.05";
        networking.firewall.enable = false;

        # The only resolver in the topology. The proxy uid is allowed to reach
        # it (proxy.allowDns); the confined uid is not, which is subtest 6.
        services.dnsmasq = {
          enable = true;
          resolveLocalQueries = false;
          settings = {
            no-resolv = true;
            log-queries = true;
            address = [
              "/allowed.test/${allowedIP}"
              "/denied.test/${deniedIP}"
            ];
          };
        };
      };
  };

  testScript = ''
    CURL = "${pkgs.curl}/bin/curl"
    RUNUSER = "${pkgs.util-linux}/bin/runuser"
    PROXY = "http://127.0.0.1:${toString proxyPort}"

    def as_uid(user, cmd):
        return RUNUSER + " -u " + user + " -- " + cmd + " 2>&1"

    def fwd(counter):
        return int(router.succeed(counter + "-count").strip())

    def fwd_reset():
        router.succeed("fwd_allow-reset")
        router.succeed("fwd_deny-reset")

    def out(counter):
        return int(agent.succeed("outcount " + counter).strip())

    start_all()

    router.wait_for_unit("multi-user.target")
    router.wait_for_unit("dnsmasq.service")
    router.wait_for_unit("fwd_allow-counter.service")
    router.wait_for_unit("fwd_deny-counter.service")
    allowed.wait_for_unit("nginx.service")
    denied.wait_for_unit("nginx.service")
    agent.wait_for_unit("multi-user.target")
    agent.wait_for_unit("agent-out-counter.service")
    agent.wait_for_unit("${name}-egress-lockdown.service")
    agent.wait_for_unit("${name}-squid.service")
    agent.wait_for_open_port(${toString proxyPort}, "127.0.0.1")

    with subtest("topology: no framework auto-addresses, destination is OFF-LINK"):
        for node, nodename in ((agent, "agent"), (allowed, "allowed"),
                               (denied, "denied"), (router, "router")):
            addrs = node.succeed("ip -4 -o addr show scope global")
            assert "192.168." not in addrs, (
                nodename + " carries a framework auto-assigned address:\n" + addrs
            )
        assert "${topo.cidr.lan}" != "${topo.cidr.ext}"
        route = agent.succeed("ip route get ${allowedIP}")
        assert "via ${routerLanIP}" in route, (
            "the destination is on-link from the confined host, so nothing transits "
            "the router and every counter-based assertion below is a tautology:\n" + route
        )

    with subtest("the lockdown table is loaded and names the confined uid"):
        table = agent.succeed("nft list table inet ${name}-egress")
        assert "meta skuid ${toString confinedUid} drop" in table, table
        assert "meta skuid ${toString proxyUid} drop" in table, table

    with subtest("1. confined uid REACHES an allowlisted destination via the proxy"):
        fwd_reset()
        agent.succeed("outreset")
        agent.succeed("truncate -s 0 ${proxyLog}")
        body = agent.succeed(as_uid(
            "${name}",
            CURL + " -sS -f -k --max-time 20 --proxy " + PROXY + " https://allowed.test/",
        )).strip()
        assert body == "${allowedBody}", "unexpected body: " + repr(body)
        # squid logged an allowed CONNECT, so the request really went via the proxy.
        proxied = agent.succeed("cat ${proxyLog}")
        assert "allowed.test:443" in proxied, proxied
        # It really went over the wire, through the router.
        assert fwd("fwd_allow") > 0, "the fetch succeeded but no packet reached the router"
        # And it was the PROXY uid that spoke to the origin, never the confined
        # one -- the confined uid only ever touched loopback.
        assert out("proxyuid_to_allowed") > 0, "the proxy uid never contacted the origin"
        assert out("confined_to_allowed") == 0, (
            "the confined uid sent packets straight at the origin during a proxied fetch"
        )

    with subtest("2. confined uid CANNOT reach a non-allowlisted destination via the proxy"):
        fwd_reset()
        agent.succeed("outreset")
        agent.succeed("truncate -s 0 ${proxyLog}")
        status, output = agent.execute(as_uid(
            "${name}",
            CURL + " -sS -k --max-time 20 --proxy " + PROXY + " https://denied.test/",
        ))
        assert status != 0, "the proxy tunnelled to a non-allowlisted domain: " + repr(output)
        assert "${deniedBody}" not in output, "the denied origin's payload came back: " + repr(output)
        assert "403" in output, "expected a squid 403, got: " + repr(output)
        # squid's own verdict, not an inference from a failed request.
        denials = agent.succeed("cat ${proxyLog}")
        assert "TCP_DENIED" in denials and "denied.test" in denials, denials
        # And it never opened a connection: this is the same counter that reads
        # non-zero for the same destination in subtest 4.
        forwarded = fwd("fwd_deny")
        assert forwarded == 0, (
            "squid opened a connection to a non-allowlisted origin ("
            + str(forwarded) + " packets forwarded)"
        )

    with subtest("3. confined uid CANNOT bypass the proxy by ignoring the env vars"):
        fwd_reset()
        agent.succeed("outreset")
        status, output = agent.execute(as_uid(
            "${name}",
            CURL + " -sS -f -k --max-time ${toString bypassTimeout} --noproxy '*' https://${allowedIP}/",
        ))
        assert status != 0, "the confined uid reached the origin directly: " + repr(output)
        assert "${allowedBody}" not in output, "the origin's payload came back: " + repr(output)
        # It SILENTLY timed out, which is what `drop` looks like from userspace.
        # Not ECONNREFUSED (nothing listening), not ENETUNREACH (no route) --
        # note that a TCP SYN never surfaces the EPERM that netfilter returns,
        # because tcp_connect() only propagates ECONNREFUSED and otherwise falls
        # back on the retransmit timer.
        assert status == 28 and "timed out" in output, (
            "expected the connection to hang and time out (a silent drop), got exit "
            + str(status) + ": " + repr(output)
        )
        # The process DID emit a packet at the destination -- so the failure is
        # a drop, not an unsent request.
        emitted = out("confined_to_allowed")
        assert emitted > 0, (
            "the confined uid never even sent a packet at the destination, so this "
            "subtest proves nothing about the drop rule"
        )
        # ...and nothing left the host.
        forwarded = fwd("fwd_allow")
        assert forwarded == 0, (
            "the router forwarded " + str(forwarded) + " packets from the confined uid: "
            "the drop rule is not in the packet path"
        )

    with subtest("4. a DIFFERENT uid on the same host is unaffected"):
        for user in ("root", "bystander"):
            fwd_reset()
            agent.succeed("outreset")
            body = agent.succeed(as_uid(
                user,
                CURL + " -sS -f -k --max-time 20 --noproxy '*' https://${allowedIP}/",
            )).strip()
            assert body == "${allowedBody}", user + " got: " + repr(body)
            assert fwd("fwd_allow") > 0, user + "'s traffic did not transit the router"
            assert out("confined_to_allowed") == 0, (
                "the confined-uid counter moved for " + user + " -- the skuid match is wrong"
            )
            # The host is not blanket-filtered: the NON-allowlisted origin is
            # reachable too, for anyone who is not the confined uid.
            other = agent.succeed(as_uid(
                user,
                CURL + " -sS -f -k --max-time 20 --noproxy '*' https://${deniedIP}/",
            )).strip()
            assert other == "${deniedBody}", user + " got: " + repr(other)

    with subtest("5. the shipped bubblewrap launcher behaves the same way"):
        agent.succeed(as_uid("${name}", "/run/current-system/sw/bin/${name}"))
        state = "/var/lib/${name}"
        assert agent.succeed("cat " + state + "/proxied-allowed.out").strip() == "${allowedBody}"
        assert "exit=0" in agent.succeed("cat " + state + "/proxied-allowed.err")
        # squid 403 -> curl --fail exits 22, and nothing is written.
        assert agent.succeed("cat " + state + "/proxied-denied.out").strip() == ""
        assert "exit=22" in agent.succeed("cat " + state + "/proxied-denied.err")
        # The in-sandbox bypass attempt: --noproxy '*' with the env vars set.
        assert agent.succeed("cat " + state + "/bypass.out").strip() == ""
        bypass_err = agent.succeed("cat " + state + "/bypass.err")
        assert "timed out" in bypass_err, bypass_err
        assert "exit=28" in bypass_err, bypass_err

    with subtest("6. the confined uid cannot resolve names either"):
        # DNS is the proxy uid's privilege; the confined uid never learns an
        # address for anything.
        agent.succeed(as_uid("${name}-proxy", "${pkgs.dnsutils}/bin/dig +short +time=3 +tries=1 "
                             + "@${routerLanIP} allowed.test | grep -qx ${allowedIP}"))
        status, output = agent.execute(as_uid(
            "${name}",
            "${pkgs.dnsutils}/bin/dig +short +time=3 +tries=1 @${routerLanIP} allowed.test",
        ))
        assert "${allowedIP}" not in output, (
            "the confined uid resolved a name: " + repr(output)
        )

    print("=== per-uid-egress-lockdown passed ===")
  '';
}
